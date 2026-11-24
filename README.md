# Q4 – Clinic Appointment Scheduling (schema `q4`)

**Purpose:** four slots per doctor per day (09:00, 10:00, 11:00, 12:00); two non-cancelled appointments may never share a doctor, date and slot.

## Objects
| Part | Object | What it does |
|---|---|---|
| (a) | `patients`, `doctors`, `appointments`, `clinic_summary` | `slot_time` is `TIME` with a CHECK; status BOOKED/ATTENDED/CANCELLED; 3 patients, 3 doctors, 6 appointments |
| (b) | `fn_daily_load(doctor, day)` | count of non-cancelled appointments; 0 for an empty day; rejects unknown doctor |
| (c) | `pr_book_appointment(patient, doctor, day, slot)` | validates IDs, rejects past dates and unsupported slots, inserts a BOOKED row |
| (d) | `trg_appointments_clash` | BEFORE INSERT OR UPDATE; rejects clashes and excludes the row being updated |
| (e) | `v_today_appointments` | today's BOOKED appointments: patient name, doctor name, slot only |
| (f) | `idx_appointments_day_doctor (appointment_day, doctor_id)` | non-unique, supports day + doctor searches |
| (g) | `pr_refresh_clinic_summary(day)` + job `q4_refresh_clinic_summary` | upsert of three status counts; cron `0 1 * * *` for yesterday |

## Extra
A partial unique index `uq_doctor_slot_active` (non-cancelled rows only) backs up the trigger against concurrent bookings.
