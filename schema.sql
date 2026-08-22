-- ============================================================
-- ECOFREE — DATABASE SCHEMA cho Cloudflare D1 (SQLite dialect)
-- PHIÊN BẢN ĐÃ SỬA LỖI THỨ TỰ BẢNG (v2)
-- ============================================================
-- Quy ước:
-- * Mọi số tiền lưu dạng SỐ NGUYÊN (cents) để tránh sai số làm tròn.
--   VD: 1234.56 AUD -> lưu 123456 (chia lại 100 khi hiển thị).
-- * SQLite không có ENUM thật -> dùng CHECK constraint.
-- * Ngày tháng lưu dạng TEXT ISO8601 ('YYYY-MM-DD').
-- ============================================================

-- Xóa sạch nếu đã có (để chạy lại an toàn, không bị lỗi "table already exists")
DROP TRIGGER IF EXISTS trg_order_autocomplete_fixed;
DROP TRIGGER IF EXISTS trg_order_autocomplete_hourly;
DROP TRIGGER IF EXISTS trg_invoice_paid_payout_hourly;
DROP TRIGGER IF EXISTS trg_invoice_paid_payout_fixed;
DROP TABLE IF EXISTS payouts;
DROP TABLE IF EXISTS reminder_log;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS billing_cycles;
DROP TABLE IF EXISTS invoices;
DROP TABLE IF EXISTS order_staff_payout;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS quotations;
DROP TABLE IF EXISTS staff;
DROP TABLE IF EXISTS clients;

-- ------------------------------------------------------------
-- 1. KHÁCH HÀNG
-- ------------------------------------------------------------
CREATE TABLE clients (
  client_id             INTEGER PRIMARY KEY AUTOINCREMENT,
  client_code           TEXT UNIQUE NOT NULL,
  company_name          TEXT NOT NULL,
  contact_person        TEXT,
  email                 TEXT,
  phone                 TEXT,
  client_pays_fee_default INTEGER NOT NULL DEFAULT 0 CHECK (client_pays_fee_default IN (0,1)),
  created_at            TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ------------------------------------------------------------
-- 2. NHÂN VIÊN
-- ------------------------------------------------------------
CREATE TABLE staff (
  staff_id              INTEGER PRIMARY KEY AUTOINCREMENT,
  staff_code            TEXT UNIQUE NOT NULL,
  full_name             TEXT NOT NULL,
  role                  TEXT NOT NULL CHECK (role IN ('estimator','drafter','admin','marketing')),
  bank_info             TEXT,
  avg_hourly_rate_cents INTEGER NOT NULL,
  management_fee_rate   INTEGER NOT NULL CHECK (management_fee_rate IN (20,30)),
  user_role             TEXT NOT NULL CHECK (user_role IN ('member','accountant','manager')),
  is_active             INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
  created_at            TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ------------------------------------------------------------
-- 3. BÁO GIÁ
-- ------------------------------------------------------------
CREATE TABLE quotations (
  quotation_id          INTEGER PRIMARY KEY AUTOINCREMENT,
  quotation_code        TEXT UNIQUE NOT NULL,
  client_id             INTEGER NOT NULL REFERENCES clients(client_id),
  project_name          TEXT NOT NULL,
  created_date          TEXT NOT NULL DEFAULT (date('now')),
  valid_until           TEXT,
  contract_type         TEXT NOT NULL CHECK (contract_type IN ('fixed','hourly')),
  fee_payer             TEXT CHECK (fee_payer IN ('client','ecofree')),
  total_amount_cents    INTEGER NOT NULL DEFAULT 0,
  status                TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','approved','rejected'))
);

-- ------------------------------------------------------------
-- 4. ĐƠN HÀNG (chung cho Loại A & B)
-- ------------------------------------------------------------
CREATE TABLE orders (
  order_id              INTEGER PRIMARY KEY AUTOINCREMENT,
  order_code            TEXT UNIQUE NOT NULL,
  quotation_id          INTEGER NOT NULL REFERENCES quotations(quotation_id),
  client_id             INTEGER NOT NULL REFERENCES clients(client_id),
  contract_type         TEXT NOT NULL CHECK (contract_type IN ('fixed','hourly')),
  fee_payer             TEXT CHECK (fee_payer IN ('client','ecofree')),
  start_date            TEXT NOT NULL DEFAULT (date('now')),
  deadline              TEXT,
  estimated_hours       REAL,
  rate_estimated        REAL NOT NULL,
  status                TEXT NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress','completed')),
  created_at            TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_orders_client ON orders(client_id);

-- ------------------------------------------------------------
-- 5. TRẢ LƯƠNG CỐ ĐỊNH (Loại A) — cần orders + staff đã có ở trên
-- ------------------------------------------------------------
CREATE TABLE order_staff_payout (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id              INTEGER NOT NULL REFERENCES orders(order_id),
  staff_id              INTEGER NOT NULL REFERENCES staff(staff_id),
  fixed_amount_cents    INTEGER NOT NULL,
  delivered_date        TEXT,
  completed             INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0,1)),
  UNIQUE(order_id, staff_id)
);

-- ------------------------------------------------------------
-- 6. HÓA ĐƠN — tạo TRƯỚC billing_cycles vì billing_cycles cần tham chiếu tới nó
-- ------------------------------------------------------------
CREATE TABLE invoices (
  invoice_id            INTEGER PRIMARY KEY AUTOINCREMENT,
  invoice_code          TEXT UNIQUE NOT NULL,
  order_id              INTEGER NOT NULL REFERENCES orders(order_id),
  client_id             INTEGER NOT NULL REFERENCES clients(client_id),
  base_amount_cents     INTEGER NOT NULL,
  transfer_fee_cents    INTEGER NOT NULL DEFAULT 0,
  total_amount_cents    INTEGER NOT NULL,
  rate_actual           REAL,
  status                TEXT NOT NULL DEFAULT 'delivered_pending'
                        CHECK (status IN ('delivered_pending','sent_within_terms','overdue','paid')),
  sent_date             TEXT,
  due_date              TEXT,
  reminder_sent         INTEGER NOT NULL DEFAULT 0 CHECK (reminder_sent IN (0,1)),
  paid_date             TEXT,
  created_at            TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_invoices_status ON invoices(status);
CREATE INDEX idx_invoices_client ON invoices(client_id);

-- ------------------------------------------------------------
-- 7. CHỐT KỲ BILLING (Loại B) — cần orders + invoices đã có ở trên
-- ------------------------------------------------------------
CREATE TABLE billing_cycles (
  cycle_id                INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id                INTEGER NOT NULL REFERENCES orders(order_id),
  period_start            TEXT NOT NULL,
  period_end              TEXT NOT NULL,
  total_client_amount_cents INTEGER NOT NULL DEFAULT 0,
  total_staff_amount_cents  INTEGER NOT NULL DEFAULT 0,
  transfer_fee_cents        INTEGER NOT NULL DEFAULT 0,
  invoice_id                INTEGER REFERENCES invoices(invoice_id)
);

-- ------------------------------------------------------------
-- 8. NHIỆM VỤ / TASK (Loại B) — cần orders + staff + billing_cycles đã có ở trên
-- ------------------------------------------------------------
CREATE TABLE tasks (
  task_id               INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id              INTEGER NOT NULL REFERENCES orders(order_id),
  task_name             TEXT NOT NULL,
  staff_id              INTEGER NOT NULL REFERENCES staff(staff_id),
  hours                 REAL NOT NULL DEFAULT 0,
  client_rate_cents     INTEGER NOT NULL,
  staff_rate_cents      INTEGER NOT NULL,
  status                TEXT NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress','completed')),
  billing_cycle_id      INTEGER REFERENCES billing_cycles(cycle_id)
);
CREATE INDEX idx_tasks_order ON tasks(order_id);
CREATE INDEX idx_tasks_staff ON tasks(staff_id);

-- ------------------------------------------------------------
-- 9. NHẬT KÝ NHẮC NỢ
-- ------------------------------------------------------------
CREATE TABLE reminder_log (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  invoice_id            INTEGER NOT NULL REFERENCES invoices(invoice_id),
  sent_at               TEXT NOT NULL DEFAULT (datetime('now')),
  channel               TEXT NOT NULL DEFAULT 'email'
);

-- ------------------------------------------------------------
-- 10. THÙ LAO / PAYOUT
-- ------------------------------------------------------------
CREATE TABLE payouts (
  payout_id             INTEGER PRIMARY KEY AUTOINCREMENT,
  staff_id              INTEGER NOT NULL REFERENCES staff(staff_id),
  order_id              INTEGER NOT NULL REFERENCES orders(order_id),
  invoice_id            INTEGER REFERENCES invoices(invoice_id),
  case_type             TEXT NOT NULL CHECK (case_type IN ('client_paid','bad_debt')),
  gross_amount_cents    INTEGER NOT NULL,
  management_fee_cents  INTEGER NOT NULL DEFAULT 0,
  tax_withheld_cents    INTEGER NOT NULL DEFAULT 0,
  net_amount_cents      INTEGER NOT NULL DEFAULT 0,
  net_amount_vnd        INTEGER,
  rate_payout           REAL,
  payout_date           TEXT,
  status                TEXT NOT NULL DEFAULT 'pending_approval'
                        CHECK (status IN ('pending_approval','approved','paid')),
  created_at            TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_payouts_staff ON payouts(staff_id);
CREATE INDEX idx_payouts_status ON payouts(status);

-- ============================================================
-- TRIGGERS — chạy sau cùng, khi mọi bảng đã tồn tại
-- ============================================================

CREATE TRIGGER trg_invoice_paid_payout_fixed
AFTER UPDATE OF status ON invoices
WHEN NEW.status = 'paid' AND OLD.status != 'paid'
  AND (SELECT contract_type FROM orders WHERE order_id = NEW.order_id) = 'fixed'
BEGIN
  INSERT INTO payouts (staff_id, order_id, invoice_id, case_type, gross_amount_cents, status)
  SELECT osp.staff_id, NEW.order_id, NEW.invoice_id, 'client_paid', osp.fixed_amount_cents, 'pending_approval'
  FROM order_staff_payout osp
  WHERE osp.order_id = NEW.order_id AND osp.completed = 1
    AND NOT EXISTS (
      SELECT 1 FROM payouts p WHERE p.order_id = NEW.order_id AND p.staff_id = osp.staff_id AND p.invoice_id = NEW.invoice_id
    );
END;

CREATE TRIGGER trg_invoice_paid_payout_hourly
AFTER UPDATE OF status ON invoices
WHEN NEW.status = 'paid' AND OLD.status != 'paid'
  AND (SELECT contract_type FROM orders WHERE order_id = NEW.order_id) = 'hourly'
BEGIN
  INSERT INTO payouts (staff_id, order_id, invoice_id, case_type, gross_amount_cents, status)
  SELECT t.staff_id, NEW.order_id, NEW.invoice_id, 'client_paid',
         CAST(SUM(t.hours * t.staff_rate_cents) AS INTEGER), 'pending_approval'
  FROM tasks t
  JOIN billing_cycles bc ON bc.cycle_id = t.billing_cycle_id
  WHERE bc.invoice_id = NEW.invoice_id
  GROUP BY t.staff_id;
END;

CREATE TRIGGER trg_order_autocomplete_hourly
AFTER UPDATE OF status ON tasks
WHEN NEW.status = 'completed'
BEGIN
  UPDATE orders
  SET status = 'completed'
  WHERE order_id = NEW.order_id
    AND contract_type = 'hourly'
    AND NOT EXISTS (SELECT 1 FROM tasks WHERE order_id = NEW.order_id AND status != 'completed')
    AND NOT EXISTS (
      SELECT 1 FROM billing_cycles WHERE order_id = NEW.order_id AND invoice_id IS NULL
    );
END;

CREATE TRIGGER trg_order_autocomplete_fixed
AFTER UPDATE OF completed ON order_staff_payout
WHEN NEW.completed = 1
BEGIN
  UPDATE orders
  SET status = 'completed'
  WHERE order_id = NEW.order_id
    AND contract_type = 'fixed'
    AND NOT EXISTS (SELECT 1 FROM order_staff_payout WHERE order_id = NEW.order_id AND completed = 0);
END;

-- ============================================================
-- LƯU Ý:
-- 1. "Quá hạn thanh toán" tự động được tính ngay trên giao diện web
--    (không cần Cron/Worker riêng) — xem index.html.
-- 2. Công thức tính net_amount_cents được tính trong
--    functions/api/calc-payout.js khi Kế toán bấm nút "Tính toán".
-- ============================================================
