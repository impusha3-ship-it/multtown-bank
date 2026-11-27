begin;
create schema if not exists multtown;
revoke all on schema multtown from public, anon, authenticated;

create table if not exists multtown.game (
  id integer primary key check (id = 1),
  closed boolean not null default false,
  host uuid not null default gen_random_uuid()
);
create table if not exists multtown.wallet (
  id integer primary key,
  name text not null,
  balance integer not null check (balance >= 0),
  code uuid not null unique default gen_random_uuid(),
  session uuid unique
);
create table if not exists multtown.transfer (
  sender integer references multtown.wallet,
  key uuid,
  recipient integer not null references multtown.wallet,
  amount integer not null check (amount > 0),
  primary key (sender, key)
);
insert into multtown.game (id) values (1) on conflict do nothing;
insert into multtown.wallet (id,name,balance) values
  (1,'Джонни Хенкс',0),(2,'Генри Бардубаба',20),(3,'Мисс Синдирелла',70),
  (4,'Мисс Белоснежка',50),(5,'Багз Бани',100),(6,'Гном Понедельник',0),
  (7,'Вильям Галлоз',350),(8,'Эрик Эдвордс',0),(9,'Ботинок Ларри',0),
  (10,'Сандра Мирроу',0),(11,'Скрудж Макдак',0),(12,'Ян Крашевич',400),
  (13,'Долли Смайл',200),(14,'Свободная роль №14',50),(15,'Свободная роль №15',50),
  (16,'Свободная роль №16',50),(17,'Свободная роль №17',50),(18,'Нора Кадр',50),
  (19,'Пуговка Пэт',50),(20,'Лео Штрих',50),(21,'Вера Блик',50),
  (22,'Катушка Клара',50),(23,'Тоби Рулетка',50),(24,'Ящик Федя',50),
  (25,'Рита Реплика',50),(26,'Лола Люрекс',50),(27,'Марк Флип',30)
on conflict do nothing;

create or replace function public.multtown_bank(action text, credential uuid default null, payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  game_row multtown.game;
  me multtown.wallet;
  prior multtown.transfer;
  target integer;
  amount_due integer;
  request_key uuid;
  is_host boolean;
begin
  if action = 'state' then
    select * into game_row from multtown.game;
  else
    select * into game_row from multtown.game for update;
  end if;
  is_host := credential is not distinct from game_row.host;
  select * into me from multtown.wallet where session = credential;

  if action = 'login' then
    if me.id is not null then raise exception 'Этот браузер уже привязан к персонажу.'; end if;
    if game_row.closed then raise exception 'Игра завершена.'; end if;
    update multtown.wallet set session = gen_random_uuid()
    where id = (payload->>'role')::integer and code = (payload->>'code')::uuid and session is null
    returning * into me;
    if not found then raise exception 'Проверьте код. Возможно, роль уже занята.'; end if;
    return jsonb_build_object('session',me.session);
  elsif action = 'pay' then
    if me.id is null then raise exception 'Войдите в кошелёк.'; end if;
    target := (payload->>'recipient')::integer;
    amount_due := (payload->>'amount')::integer;
    request_key := (payload->>'key')::uuid;
    select * into prior from multtown.transfer where sender = me.id and key = request_key;
    if found then
      if prior.recipient is distinct from target or prior.amount is distinct from amount_due then
        raise exception 'Запрос уже использован.';
      end if;
      return '{}'::jsonb;
    end if;
    if game_row.closed then raise exception 'Игра завершена.'; end if;
    if amount_due is null or amount_due < 1 then raise exception 'Введите целую положительную сумму.'; end if;
    if me.balance < amount_due then raise exception 'Недостаточно денег.'; end if;
    if target = me.id or not exists (select 1 from multtown.wallet where id = target and session is not null) then
      raise exception 'Выберите другого подключённого игрока.';
    end if;
    update multtown.wallet set balance = balance - amount_due where id = me.id;
    update multtown.wallet set balance = balance + amount_due where id = target;
    insert into multtown.transfer values (me.id,request_key,target,amount_due);
    return '{}'::jsonb;
  elsif action = 'finish' then
    if not is_host then raise exception 'Только для ведущего.'; end if;
    update multtown.game set closed = true;
    return '{}'::jsonb;
  elsif action is distinct from 'state' then
    raise exception 'Неизвестное действие.';
  end if;

  if is_host then
    return jsonb_build_object(
      'closed',game_row.closed,
      'count',(select count(*) from multtown.transfer),
      'wallets',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'balance',balance,'joined',session is not null) order by balance desc,id) from multtown.wallet),
      'invitations',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'code',code) order by id) from multtown.wallet)
    );
  end if;
  return jsonb_build_object(
    'closed',game_row.closed,
    'player',case when me.id is not null then jsonb_build_object('id',me.id,'name',me.name,'balance',me.balance) end,
    'roles',(select jsonb_agg(jsonb_build_object('id',id,'name',name) order by id) from multtown.wallet),
    'recipients',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by id) from multtown.wallet where session is not null),'[]'::jsonb)
  );
end;
$$;
revoke execute on function public.multtown_bank(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.multtown_bank(text,uuid,jsonb) to anon;
commit;

-- Ключ ведущего виден только в SQL Editor. Не публикуйте результат запроса.
select host from multtown.game;
