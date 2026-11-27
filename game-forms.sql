begin;

alter table multtown.wallet add column if not exists recovery_pin text unique;
do $$
declare
  wallet_id integer;
  pin text;
begin
  for wallet_id in select id from multtown.wallet where recovery_pin is null loop
    loop
      pin := lpad(floor(random()*10000)::integer::text,4,'0');
      exit when not exists (select 1 from multtown.wallet where recovery_pin=pin);
    end loop;
    update multtown.wallet set recovery_pin=pin where id=wallet_id;
  end loop;
end;
$$;
create table if not exists multtown.recovery_limit (
  surname text primary key,
  started timestamptz not null,
  attempts integer not null
);

create table if not exists multtown.form_record (
  owner integer references multtown.wallet,
  kind text,
  body jsonb not null,
  submitted boolean not null default false,
  primary key (owner,kind)
);
alter table multtown.form_record add column if not exists revision uuid not null default gen_random_uuid();
create table if not exists multtown.form_signature (
  owner integer,
  kind text,
  slot integer,
  signer integer not null references multtown.wallet,
  signed boolean not null default false,
  primary key (owner,kind,slot),
  foreign key (owner,kind) references multtown.form_record
);
create table if not exists multtown.vote (
  judge integer primary key references multtown.wallet check (judge in (7,11,12)),
  candidate integer not null references multtown.wallet check (candidate in (3,4))
);
create table if not exists multtown.goal_result (
  wallet integer primary key references multtown.wallet,
  result text not null check (result in ('complete','partial','missed'))
);
create table if not exists multtown.will_decision (
  id integer primary key check (id=1),
  owner integer not null references multtown.wallet,
  action text not null check (action in ('present','destroy')),
  created timestamptz not null default now()
);

create or replace function multtown.forms_spec()
returns jsonb language sql immutable set search_path = '' as $$
  select '[
    {"id":"witness","owner":14,"title":"Показания о посетителе","fields":["Время и приметы","С кем сверили показания"],"signers":[]},
    {"id":"photo","owner":18,"title":"Материалы расследования","fields":["Описание снимка","Имя свидетеля и его показания"],"signers":[]},
    {"id":"screening","owner":21,"title":"Разрешение на благотворительный показ","fields":["Условия показа и передача сбора на лечение сына Джонни"],"signers":[-1,1],"labels":["Владелец кассеты","Джонни Хенкс"]},
    {"id":"route","owner":23,"title":"Запасной маршрут дороги","fields":["Условия. Главный павильон сохраняется, склад декораций переезжает"],"signers":[24,7],"labels":["Ящик Федя","Вильям Галлоз"]},
    {"id":"moving","owner":24,"title":"Смета перевозки декораций","fields":["Сколько собрано из необходимых 20 к."],"signers":[24],"labels":["Ящик Федя"]},
    {"id":"interview","owner":25,"title":"Интервью и заметка","fields":["Событие","Слова первого собеседника","Слова второго собеседника","Заметка для ведущего с указанием источников"],"signers":[0,0],"labels":["Первый собеседник","Второй собеседник"]},
    {"id":"credit","owner":26,"title":"Подтверждение авторства","fields":["Автор эскизов — Лола Люрекс. Дополнительные сведения"],"signers":[3,4],"labels":["Синдирелла","Белоснежка"]},
    {"id":"rental","owner":27,"title":"Разрешение на аренду кассеты","fields":["Условия аренды и сумма (до 30 к.)"],"signers":[-1],"labels":["Владелец кассеты"]},
    {"id":"joint","owner":27,"title":"Совместный показ с Верой","fields":["О чём договорились"],"signers":[21],"labels":["Вера Блик"]},
    {"id":"intro","owner":16,"title":"Выступление перед показом","fields":["Договорённость с организатором показа"],"signers":[-2],"labels":["Организатор показа (Вера или Марк)"]}
  ]'::jsonb;
$$;

create or replace function public.multtown_forms(op text, credential uuid, data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  g multtown.game;
  me integer;
  host boolean;
  spec jsonb;
  record_row multtown.form_record;
  form_kind text := data->>'kind';
  form_owner integer;
  signature_slot integer;
  expected integer;
  signer_id integer;
  chosen integer;
  attempts_used integer;
  family text;
  wheel_docs jsonb := multtown.forms_spec();
begin
  if op = 'state' then select * into g from multtown.game where id=1;
  else select * into g from multtown.game where id=1 for update; end if;
  host := coalesce(credential = g.host,false);
  select id into me from multtown.wallet where session=credential;
  if op='goal_public' then
    return jsonb_build_object('closed',g.closed,
      'votes',case when g.closed then (select coalesce(jsonb_agg(jsonb_build_object('id',candidate)),'[]') from multtown.vote) end,
      'results',case when g.closed then
      (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'name',w.name,'result',r.result) order by w.id),'[]')
       from multtown.goal_result r join multtown.wallet w on w.id=r.wallet where w.session is not null)
      else '[]'::jsonb end);
  end if;
  if op='goal_set' then
    if not host then raise exception 'Только для ведущего.'; end if;
    chosen := (data->>'role')::integer;
    if not exists(select 1 from multtown.wallet where id=chosen and session is not null) then
      raise exception 'Роль ещё не занята.';
    end if;
    if data->>'result' is null then
      delete from multtown.goal_result where wallet=chosen;
    else
      insert into multtown.goal_result (wallet,result) values (chosen,data->>'result')
      on conflict (wallet) do update set result=excluded.result;
    end if;
    return '{}'::jsonb;
  end if;
  if op='recover' then
    if credential is null or host or me is not null then raise exception 'Откройте игру в браузере без действующей роли.'; end if;
    family := lower(btrim(data->>'surname'));
    if data->>'code' is null or (data->>'code') !~ '^[0-9]{4}$'
       or not exists (select 1 from multtown.wallet where session is not null and lower(surname)=family) then
      return jsonb_build_object('error','Фамилия или личный код не подошли.');
    end if;
    insert into multtown.recovery_limit as limits values (family,clock_timestamp(),1)
    on conflict (surname) do update set
      attempts=case when limits.started < clock_timestamp()-interval '10 minutes' then 1 else least(limits.attempts+1,6) end,
      started=case when limits.started < clock_timestamp()-interval '10 minutes' then clock_timestamp() else limits.started end
    returning attempts into attempts_used;
    if attempts_used>5 then return jsonb_build_object('error','Слишком много попыток. Повторите через 10 минут.'); end if;
    update multtown.wallet set session=credential
    where session is not null and recovery_pin=data->>'code' and lower(surname)=family;
    if not found then return jsonb_build_object('error','Фамилия или личный код не подошли.'); end if;
    return '{}'::jsonb;
  end if;
  if not host and me is null then raise exception 'Войдите в игру.'; end if;
  if op = 'state' then
    return jsonb_build_object(
      'spec', (select coalesce(jsonb_agg(f),'[]') from jsonb_array_elements(wheel_docs) f where host or (f->>'owner')::integer=me),
      'goals',case when host then (select coalesce(jsonb_object_agg(wallet,result),'{}') from multtown.goal_result) end,
      'recovery',case when host then (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'surname',surname,'code',recovery_pin) order by id),'[]')
        from multtown.wallet where session is not null)
        else (select to_jsonb(recovery_pin) from multtown.wallet where id=me) end,
      'forms',(select coalesce(jsonb_agg(jsonb_build_object('owner',r.owner,'kind',r.kind,'title',f->>'title','fields',f->'fields',
        'body',r.body,'submitted',r.submitted,'revision',r.revision,
        'signatures',(select coalesce(jsonb_agg(jsonb_build_object('slot',s.slot,'signer',s.signer,'name',w.name,'signed',s.signed) order by s.slot),'[]')
          from multtown.form_signature s join multtown.wallet w on w.id=s.signer where s.owner=r.owner and s.kind=r.kind and (host or r.owner=me or s.signer=me)))),
        '[]') from multtown.form_record r join lateral jsonb_array_elements(wheel_docs) f on f->>'id'=r.kind
        where host or r.owner=me or exists (select 1 from multtown.form_signature s where s.owner=r.owner and s.kind=r.kind and s.signer=me)),
      'vote', (select candidate from multtown.vote where judge=me),
      'votes',case when host or g.closed then (select coalesce(jsonb_agg(jsonb_build_object('judge',j.name,'candidate',c.name,'id',c.id) order by v.judge),'[]')
        from multtown.vote v join multtown.wallet j on j.id=v.judge join multtown.wallet c on c.id=v.candidate) end,
      'will',case when host then (select jsonb_build_object('name',w.name,'action',d.action) from multtown.will_decision d join multtown.wallet w on w.id=d.owner) end
    );
  end if;
  if g.closed then raise exception 'Игра завершена.'; end if;
  if me is null then raise exception 'Действие доступно только игроку.'; end if;
  if op='vote' then
    chosen := (data->>'candidate')::integer;
    if me not in (7,11,12) or chosen is null or chosen not in (3,4) then raise exception 'Недопустимый голос.'; end if;
    insert into multtown.vote values (me,chosen) on conflict do nothing;
    if not found then raise exception 'Вы уже подписали бланк.'; end if;
    return '{}'::jsonb;
  elsif op in ('present','destroy') then
    if op='destroy' and me<>7 then raise exception 'Уничтожить завещание может Галлоз.'; end if;
    update multtown.item set spent=true where id=1 and owner=me and not spent;
    if not found then raise exception 'Завещание у другого игрока или уже предъявлено.'; end if;
    insert into multtown.will_decision (id,owner,action) values (1,me,op);
    return '{}'::jsonb;
  elsif op='sign' then
    form_owner := (data->>'owner')::integer;
    signature_slot := (data->>'slot')::integer;
    select * into record_row from multtown.form_record where owner=form_owner and kind=form_kind;
    if record_row.revision is distinct from (data->>'revision')::uuid then
      raise exception 'Бланк изменился. Обновите страницу и перечитайте его.';
    end if;
    if form_kind in ('rental','screening') and (form_kind='rental' or signature_slot=0)
       and not exists (select 1 from multtown.item where id=2 and owner=me and not spent) then
      raise exception 'Бланк должен подписать текущий владелец кассеты.';
    end if;
    update multtown.form_signature set signed=true
    where owner=form_owner and kind=form_kind and slot=signature_slot and signer=me and not signed;
    if not found then raise exception 'Этот запрос уже обработан или предназначен другому игроку.'; end if;
    return '{}'::jsonb;
  end if;

  select f into spec from jsonb_array_elements(wheel_docs) f where f->>'id'=form_kind and (f->>'owner')::integer=me;
  if spec is null then raise exception 'У этой роли нет такого бланка.'; end if;
  select * into record_row from multtown.form_record where owner=me and kind=form_kind;
  if op='submit' then
    if record_row.owner is null or exists (select 1 from multtown.form_signature where owner=me and kind=form_kind and not signed)
       or jsonb_array_length(spec->'signers') <> (select count(*) from multtown.form_signature where owner=me and kind=form_kind) then
      raise exception 'Сначала заполните бланк и соберите все подписи.';
    end if;
    update multtown.form_record set submitted=true where owner=me and kind=form_kind;
  elsif op='save' then
    if record_row.submitted or exists (select 1 from multtown.form_signature where owner=me and kind=form_kind and signed) then
      raise exception 'Подписанный или отправленный бланк нельзя изменить.';
    end if;
    if jsonb_typeof(data->'body') is distinct from 'array' or jsonb_array_length(data->'body') <> jsonb_array_length(spec->'fields')
       or exists (select 1 from jsonb_array_elements(data->'body') v where jsonb_typeof(v)<>'string' or char_length(btrim(v#>>'{}')) not between 1 and 1500) then
      raise exception 'Заполните все поля (до 1500 символов в каждом).';
    end if;
    delete from multtown.form_signature where owner=me and kind=form_kind;
    insert into multtown.form_record (owner,kind,body) values (me,form_kind,data->'body')
      on conflict (owner,kind) do update set body=excluded.body, revision=excluded.revision;
    for signature_slot in 0 .. jsonb_array_length(spec->'signers')-1 loop
      expected := (spec->'signers'->>signature_slot)::integer;
      signer_id := expected;
      if expected=-1 then
        select owner into signer_id from multtown.item where id=2 and not spent;
      elsif expected in (0,-2) then
        signer_id := (data->'signers'->>signature_slot)::integer;
      end if;
      if signer_id is null or (expected=0 and signer_id=me) or (expected=-2 and signer_id not in (21,27))
         or not exists (select 1 from multtown.wallet where id=signer_id and session is not null)
         or exists (select 1 from multtown.form_signature where owner=me and kind=form_kind and signer=signer_id and form_kind='interview') then
        raise exception 'Выберите доступных подписантов. Для интервью нужны два разных игрока.';
      end if;
      insert into multtown.form_signature values (me,form_kind,signature_slot,signer_id,false);
    end loop;
  else
    raise exception 'Неизвестное действие.';
  end if;
  return '{}'::jsonb;
end;
$$;
revoke all on function public.multtown_forms(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.multtown_forms(text,uuid,jsonb) to anon;
commit;
