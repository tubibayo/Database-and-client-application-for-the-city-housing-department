-- 1. СОЗДАНИЕ ТАБЛИЦ

-- Районы
CREATE TABLE areas (
    area_key   INT PRIMARY KEY,
    name       TEXT,
    responsible TEXT NOT NULL
);

-- Дома 
CREATE TABLE houses (
    area_key      INT NOT NULL,
    house_key     INT PRIMARY KEY,
    region        TEXT NOT NULL,
    street        TEXT NOT NULL,
    number        TEXT NOT NULL,
    building      TEXT,
    total_area    REAL NOT NULL,
    territory_area REAL NOT NULL,
    floors_count  INT NOT NULL,
    FOREIGN KEY (area_key) REFERENCES areas(area_key) ON DELETE CASCADE,
    CHECK (floors_count > 0)
);

-- Помещения 
CREATE TABLE premises (
    house_key      INT NOT NULL,
    premises_key   INT PRIMARY KEY,
    type           VARCHAR(7) NOT NULL,
    total_area     REAL NOT NULL,
    living_area    REAL,
    floor          INT NOT NULL,
    privatization  BOOL NOT NULL,
    cold_water     BOOL NOT NULL,
    hot_water      BOOL NOT NULL,
    garbage_chute  BOOL NOT NULL,
    elevator       BOOL NOT NULL,
    total_debt     NUMERIC DEFAULT 0,   -- денормализованное поле для суммы долгов
    FOREIGN KEY (house_key) REFERENCES houses(house_key) ON DELETE CASCADE,
    CHECK (total_area > 0),
    CHECK (living_area IS NULL OR total_area > living_area)
);

-- Коды плательщиков 
CREATE TABLE payer_codes (
    id                 SERIAL PRIMARY KEY,
    payer_key          INT UNIQUE NOT NULL,
    premises_key       INT NOT NULL,
    percentage_payment INT NOT NULL DEFAULT 100,
    FOREIGN KEY (premises_key) REFERENCES premises(premises_key) ON DELETE CASCADE,
    CHECK (percentage_payment >= 0 AND percentage_payment <= 100)
);

-- Люди 
CREATE TABLE people (
    id                  SERIAL PRIMARY KEY,
    premises_key        INT NOT NULL,
    surname             TEXT NOT NULL,
    name                TEXT NOT NULL,
    patronymic          TEXT,
    date_of_birth       DATE NOT NULL,
    identity_document   TEXT NOT NULL,
    responsible_tenant  BOOL NOT NULL DEFAULT false,
    registration        BOOL NOT NULL,
    percentage_ownership INT NOT NULL DEFAULT 0,
    start_date          DATE NOT NULL,
    end_date            DATE,
    payer_key           INT NOT NULL,
    FOREIGN KEY (premises_key) REFERENCES premises(premises_key) ON DELETE CASCADE,
    FOREIGN KEY (payer_key) REFERENCES payer_codes(payer_key) ON DELETE CASCADE,
    CHECK (percentage_ownership >= 0 AND percentage_ownership <= 100),
    CHECK (end_date IS NULL OR end_date >= start_date)
);

-- Службы
CREATE TABLE services (
    services_key INT PRIMARY KEY,
    name         TEXT NOT NULL,
    responsible  TEXT NOT NULL
);

-- Отделы служб 
CREATE TABLE service_departments (
    services_key  INT NOT NULL,
    department_key INT PRIMARY KEY,
    name          TEXT NOT NULL,
    responsible   TEXT NOT NULL,
    FOREIGN KEY (services_key) REFERENCES services(services_key) ON DELETE CASCADE
);

-- Распределение служб по районам и отделам
CREATE TABLE distribution_services (
    id             SERIAL PRIMARY KEY,
    area_key       INT NOT NULL,
    department_key INT NOT NULL,
    FOREIGN KEY (area_key) REFERENCES areas(area_key) ON DELETE CASCADE,
    FOREIGN KEY (department_key) REFERENCES service_departments(department_key) ON DELETE CASCADE
);

-- Платежи
CREATE TABLE payments (
    id             SERIAL PRIMARY KEY,
    payer_key      INT NOT NULL,
    accrual_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    accrual_amount NUMERIC NOT NULL,
    paid_amount    NUMERIC NOT NULL DEFAULT 0,
    FOREIGN KEY (payer_key) REFERENCES payer_codes(payer_key) ON DELETE CASCADE
);

-- 2. ФУНКЦИИ И ТРИГГЕРЫ ДЛЯ КОНТРОЛЯ СУММ ДОЛЕЙ

-- Проверка суммы долей владения (people)
CREATE OR REPLACE FUNCTION check_ownership_sum()
RETURNS TRIGGER AS $$
DECLARE
    total_share NUMERIC;
BEGIN
    SELECT SUM(percentage_ownership) INTO total_share
    FROM people
    WHERE premises_key = NEW.premises_key
      AND (TG_OP = 'DELETE' OR id != COALESCE(NEW.id, -1));
    
    IF COALESCE(total_share, 0) + COALESCE(NEW.percentage_ownership, 0) > 100 THEN
        RAISE EXCEPTION 'Сумма долей владения для помещения % не может превышать 100 (текущая: %, добавляемая: %)',
                        NEW.premises_key, COALESCE(total_share, 0), NEW.percentage_ownership;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_ownership_sum
BEFORE INSERT OR UPDATE OF percentage_ownership ON people
FOR EACH ROW EXECUTE FUNCTION check_ownership_sum();

-- Проверка суммы процентов оплаты (payer_codes)
CREATE OR REPLACE FUNCTION check_payment_percent_sum()
RETURNS TRIGGER AS $$
DECLARE
    total_percent NUMERIC;
BEGIN
    SELECT SUM(percentage_payment) INTO total_percent
    FROM payer_codes
    WHERE premises_key = NEW.premises_key
      AND (TG_OP = 'DELETE' OR id != COALESCE(NEW.id, -1));
    
    IF COALESCE(total_percent, 0) + COALESCE(NEW.percentage_payment, 0) > 100 THEN
        RAISE EXCEPTION 'Сумма процентов оплаты для помещения % не может превышать 100 (текущая: %, добавляемая: %)',
                        NEW.premises_key, COALESCE(total_percent, 0), NEW.percentage_payment;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_payment_percent_sum
BEFORE INSERT OR UPDATE OF percentage_payment ON payer_codes
FOR EACH ROW EXECUTE FUNCTION check_payment_percent_sum();

-- 3. ТРИГГЕР ДЛЯ ПОДДЕРЖКИ ДЕНОРМАЛИЗОВАННОГО ПОЛЯ total_debt

-- Функция обновления долга помещения при изменениях в платежах или связи плательщика
CREATE OR REPLACE FUNCTION update_premises_debt()
RETURNS TRIGGER AS $$
DECLARE
    affected_premises_key INT;
BEGIN
    -- Определяем помещение, которое изменилось (из старой или новой записи)
    IF TG_OP = 'DELETE' THEN
        SELECT premises_key INTO affected_premises_key
        FROM payer_codes WHERE payer_key = OLD.payer_key;
    ELSE
        SELECT premises_key INTO affected_premises_key
        FROM payer_codes WHERE payer_key = NEW.payer_key;
    END IF;

    -- Пересчитываем total_debt как сумму (accrual_amount - paid_amount) по всем платежам этого помещения
    UPDATE premises SET total_debt = (
        SELECT COALESCE(SUM(p.accrual_amount - p.paid_amount), 0)
        FROM payer_codes pc
        JOIN payments p ON pc.payer_key = p.payer_key
        WHERE pc.premises_key = affected_premises_key
    )
    WHERE premises_key = affected_premises_key;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Триггеры на изменения в платежах
CREATE TRIGGER trg_payments_update_debt
AFTER INSERT OR UPDATE OR DELETE ON payments
FOR EACH ROW EXECUTE FUNCTION update_premises_debt();

-- Триггер на изменение связи payer_codes.premises_key 
CREATE TRIGGER trg_payercodes_update_debt
AFTER UPDATE OF premises_key ON payer_codes
FOR EACH ROW EXECUTE FUNCTION update_premises_debt();

-- 4. ИНДЕКСЫ ДЛЯ ПРОИЗВОДИТЕЛЬНОСТИ

CREATE INDEX idx_people_surname ON people(surname);
CREATE INDEX idx_people_registration ON people(registration);
CREATE INDEX idx_premises_type ON premises(type);
CREATE INDEX idx_premises_floor ON premises(floor);
CREATE INDEX idx_payments_accrual_date ON payments(accrual_date);
CREATE INDEX idx_payments_payer_key ON payments(payer_key);
CREATE INDEX idx_premises_house_key ON premises(house_key);
CREATE INDEX idx_houses_area_key ON houses(area_key);
CREATE INDEX idx_payer_codes_premises_key ON payer_codes(premises_key);
CREATE INDEX idx_houses_street ON houses(street);
CREATE INDEX idx_people_payer_key ON people(payer_key);

-- 5. ПРЕДСТАВЛЕНИЯ (VIEW)

-- 5.1. По одной таблице: активные прописанные граждане
CREATE VIEW v_active_registered_people AS
SELECT surname, name, patronymic, date_of_birth, identity_document, premises_key
FROM people
WHERE registration = true AND (end_date IS NULL OR end_date > CURRENT_DATE);

-- 5.2. По нескольким таблицам: детальная информация о платежах
CREATE VIEW v_payments_full AS
SELECT 
    p.id AS payment_id,
    p.accrual_date,
    p.accrual_amount,
    p.paid_amount,
    pc.payer_key,
    pc.percentage_payment,
    pr.premises_key,
    pr.type AS premises_type,
    pr.total_area,
    h.house_key,
    h.street,
    h.number,
    a.area_key,
    a.name AS area_name
FROM payments p
JOIN payer_codes pc ON p.payer_key = pc.payer_key
JOIN premises pr ON pc.premises_key = pr.premises_key
JOIN houses h ON pr.house_key = h.house_key
JOIN areas a ON h.area_key = a.area_key;

-- 5.3. С GROUP BY и HAVING: помещения с суммой начислений > 50000
CREATE VIEW v_high_accrual_premises AS
SELECT 
    pr.premises_key,
    pr.type,
    SUM(p.accrual_amount) AS total_accrual
FROM premises pr
JOIN payer_codes pc ON pr.premises_key = pc.premises_key
JOIN payments p ON pc.payer_key = p.payer_key
GROUP BY pr.premises_key, pr.type
HAVING SUM(p.accrual_amount) > 50000;

-- 5.4. Для отчета по прописанным гражданам
CREATE OR REPLACE VIEW v_active_people_full AS
SELECT 
	a.area_key,
    a.name AS area_name,
    p.surname,
    p.name,
    p.patronymic,
    p.date_of_birth,
    p.responsible_tenant,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, p.date_of_birth)) AS age
FROM people p
JOIN premises pr ON p.premises_key = pr.premises_key
JOIN houses h ON pr.house_key = h.house_key
JOIN areas a ON h.area_key = a.area_key
WHERE p.registration = true 
  AND (p.end_date IS NULL OR p.end_date > CURRENT_DATE);
