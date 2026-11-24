/* #####################################################################
   QUESTION 4 - Clinic Appointment Scheduling
   ##################################################################### */
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4, public;

-- (a) Tables ------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

-- Concurrency safety net (the trigger gives the friendly error message first).
CREATE UNIQUE INDEX uq_doctor_slot_active
    ON appointments (doctor_id, appointment_day, slot_time) WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

-- (b) Function ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM appointments
    WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
    RETURN v_count;                           -- COUNT(*) gives 0 for an empty day
END $$;

-- (c) Procedure ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id; END IF;
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id; END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks the clash
END $$;

-- (d) Trigger -----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        PERFORM 1 FROM appointments a
        WHERE a.doctor_id       = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time       = NEW.slot_time
          AND a.status         <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id);  -- skip self on UPDATE
        IF FOUND THEN
            RAISE EXCEPTION 'Clash: doctor % already has a booking on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_clash();

-- (a) continued: seed data ----------------------------------------------
INSERT INTO patients (full_name) VALUES ('Grace Nkandu'), ('Henry Sakala'), ('Irene Daka');
INSERT INTO doctors  (full_name) VALUES ('Dr. Kabwe'), ('Dr. Mumba'), ('Dr. Simbeye');

CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '10:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '11:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '12:00');

UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;
UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 5;

-- Trigger demonstration: clash is rejected, a self-update is allowed
DO $$
BEGIN
    BEGIN
        CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');       -- clash with #1
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Rejected as expected: %', SQLERRM;
    END;
END $$;
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 2;   -- re-activate: no clash
UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 1; -- own row excluded

SELECT fn_daily_load(1, CURRENT_DATE) AS load_dr1_today,              -- 2
       fn_daily_load(1, CURRENT_DATE + 30) AS load_empty_day;         -- 0

-- (e) View --------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index -------------------------------------------------------------
-- Non-unique: a doctor may have several bookings per day. Day first (equality or
-- range on the day), then doctor, supports "who is booked on this day for doctor X".
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count = EXCLUDED.booked_count,
            attended_count = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END $$;

SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
       $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);            -- rerun replaces
SELECT * FROM clinic_summary;

