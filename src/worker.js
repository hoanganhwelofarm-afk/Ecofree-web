// src/worker.js
// Worker duy nhất xử lý: phục vụ giao diện tĩnh (public/index.html) VÀ toàn bộ API /api/...
// Đây là mô hình "Workers + Static Assets" mới của Cloudflare (thay thế Pages Functions).

const TABLES = {
  clients: { pk: "client_id", columns: ["client_code","company_name","contact_person","email","phone","client_pays_fee_default"] },
  staff: { pk: "staff_id", columns: ["staff_code","full_name","role","bank_info","avg_hourly_rate_cents","management_fee_rate","user_role","is_active"] },
  quotations: { pk: "quotation_id", columns: ["quotation_code","client_id","project_name","created_date","valid_until","contract_type","fee_payer","total_amount_cents","status"] },
  orders: { pk: "order_id", columns: ["order_code","quotation_id","client_id","contract_type","fee_payer","start_date","deadline","estimated_hours","rate_estimated","status"] },
  order_staff_payout: { pk: "id", columns: ["order_id","staff_id","fixed_amount_cents","delivered_date","completed"] },
  tasks: { pk: "task_id", columns: ["order_id","task_name","staff_id","hours","client_rate_cents","staff_rate_cents","status","billing_cycle_id"] },
  billing_cycles: { pk: "cycle_id", columns: ["order_id","period_start","period_end","total_client_amount_cents","total_staff_amount_cents","transfer_fee_cents","invoice_id"] },
  invoices: { pk: "invoice_id", columns: ["invoice_code","order_id","client_id","base_amount_cents","transfer_fee_cents","total_amount_cents","rate_actual","status","sent_date","due_date","reminder_sent","paid_date"] },
  payouts: { pk: "payout_id", columns: ["staff_id","order_id","invoice_id","case_type","gross_amount_cents","management_fee_cents","tax_withheld_cents","net_amount_cents","net_amount_vnd","rate_payout","payout_date","status"] }
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      try {
        return await handleApi(request, env, url);
      } catch (e) {
        return json({ error: "Lỗi máy chủ: " + e.message }, 500);
      }
    }
    // Không phải /api -> trả về file tĩnh (index.html, css, js...) từ thư mục public
    return env.ASSETS.fetch(request);
  }
};

async function handleApi(request, env, url) {
  const parts = url.pathname.split("/").filter(Boolean); // ["api", "clients"] hoặc ["api","approve-quotation"]
  const resource = parts[1];

  if (resource === "approve-quotation" && request.method === "POST") return approveQuotation(request, env);
  if (resource === "calc-payout" && request.method === "POST") return calcPayout(request, env);
  if (resource === "report" && request.method === "GET") return getReport(request, env, url);
  if (resource === "close-billing-cycle" && request.method === "POST") return closeBillingCycle(request, env);

  const cfg = TABLES[resource];
  if (!cfg) return json({ error: "Bảng không hợp lệ: " + resource }, 400);

  if (request.method === "GET") return listOrGet(request, env, resource, cfg, url);
  if (request.method === "POST") return createRecord(request, env, resource, cfg);
  if (request.method === "PUT") return updateRecord(request, env, resource, cfg, url);
  if (request.method === "DELETE") return deleteRecord(request, env, resource, cfg, url);
  return json({ error: "Phương thức không hỗ trợ" }, 405);
}

async function listOrGet(request, env, table, cfg, url) {
  const id = url.searchParams.get("id");
  if (id) {
    const row = await env.DB.prepare(`SELECT * FROM ${table} WHERE ${cfg.pk} = ?`).bind(id).first();
    return json(row || null);
  }
  const { results } = await env.DB.prepare(`SELECT * FROM ${table} ORDER BY ${cfg.pk} DESC`).all();
  return json(results);
}

async function createRecord(request, env, table, cfg) {
  const body = await request.json();
  const cols = cfg.columns.filter((c) => body[c] !== undefined);
  if (cols.length === 0) return json({ error: "Không có dữ liệu hợp lệ để tạo" }, 400);
  const placeholders = cols.map(() => "?").join(",");
  const res = await env.DB.prepare(`INSERT INTO ${table} (${cols.join(",")}) VALUES (${placeholders})`)
    .bind(...cols.map((c) => body[c])).run();
  return json({ id: res.meta.last_row_id, success: true });
}

async function updateRecord(request, env, table, cfg, url) {
  const id = url.searchParams.get("id");
  if (!id) return json({ error: "Thiếu id để cập nhật" }, 400);
  const body = await request.json();
  const cols = cfg.columns.filter((c) => body[c] !== undefined);
  if (cols.length === 0) return json({ error: "Không có dữ liệu hợp lệ để cập nhật" }, 400);
  const setClause = cols.map((c) => `${c} = ?`).join(", ");
  await env.DB.prepare(`UPDATE ${table} SET ${setClause} WHERE ${cfg.pk} = ?`)
    .bind(...cols.map((c) => body[c]), id).run();
  return json({ success: true });
}

async function deleteRecord(request, env, table, cfg, url) {
  const id = url.searchParams.get("id");
  if (!id) return json({ error: "Thiếu id để xóa" }, 400);
  await env.DB.prepare(`DELETE FROM ${table} WHERE ${cfg.pk} = ?`).bind(id).run();
  return json({ success: true });
}

async function approveQuotation(request, env) {
  const { quotation_id, order_code } = await request.json();
  if (!quotation_id) return json({ error: "Thiếu quotation_id" }, 400);
  if (!order_code) return json({ error: "Thiếu order_code (Mã đơn hàng)" }, 400);
  const q = await env.DB.prepare("SELECT * FROM quotations WHERE quotation_id = ?").bind(quotation_id).first();
  if (!q) return json({ error: "Không tìm thấy báo giá" }, 404);
  if (q.status === "approved") return json({ error: "Báo giá này đã được duyệt trước đó" }, 400);
  const res = await env.DB.prepare(
    `INSERT INTO orders (order_code, quotation_id, client_id, contract_type, fee_payer, start_date, rate_estimated, status)
     VALUES (?, ?, ?, ?, ?, date('now'), 1, 'in_progress')`
  ).bind(order_code, q.quotation_id, q.client_id, q.contract_type, q.fee_payer).run();
  await env.DB.prepare("UPDATE quotations SET status = 'approved' WHERE quotation_id = ?").bind(quotation_id).run();
  return json({ success: true, order_id: res.meta.last_row_id, order_code });
}

async function closeBillingCycle(request, env) {
  const { order_id, period_start, period_end } = await request.json();
  if (!order_id || !period_start || !period_end) return json({ error: "Thiếu order_id/period_start/period_end" }, 400);

  const { results: doneTasks } = await env.DB.prepare(
    `SELECT * FROM tasks WHERE order_id = ? AND status = 'completed' AND billing_cycle_id IS NULL`
  ).bind(order_id).all();

  if (doneTasks.length === 0) return json({ error: "Không có Task nào đã hoàn thành và chưa được chốt kỳ trước đó" }, 400);

  const totalClient = doneTasks.reduce((s, t) => s + Math.round(t.hours * t.client_rate_cents), 0);
  const totalStaff = doneTasks.reduce((s, t) => s + Math.round(t.hours * t.staff_rate_cents), 0);

  const res = await env.DB.prepare(
    `INSERT INTO billing_cycles (order_id, period_start, period_end, total_client_amount_cents, total_staff_amount_cents, transfer_fee_cents)
     VALUES (?, ?, ?, ?, ?, 0)`
  ).bind(order_id, period_start, period_end, totalClient, totalStaff).run();

  const cycleId = res.meta.last_row_id;
  for (const t of doneTasks) {
    await env.DB.prepare(`UPDATE tasks SET billing_cycle_id = ? WHERE task_id = ?`).bind(cycleId, t.task_id).run();
  }

  return json({ success: true, cycle_id: cycleId, total_client_amount_cents: totalClient, total_staff_amount_cents: totalStaff, task_count: doneTasks.length });
}

async function getReport(request, env, url) {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  if (!from || !to) return json({ error: "Thiếu khoảng thời gian (from, to)" }, 400);

  const revenue = await env.DB.prepare(
    `SELECT COALESCE(SUM(total_amount_cents),0) AS v FROM invoices WHERE status = 'paid' AND paid_date BETWEEN ? AND ?`
  ).bind(from, to).first();

  const mgmtFee = await env.DB.prepare(
    `SELECT COALESCE(SUM(p.management_fee_cents),0) AS v
     FROM payouts p JOIN invoices i ON p.invoice_id = i.invoice_id
     WHERE i.paid_date BETWEEN ? AND ?`
  ).bind(from, to).first();

  const staffPaid = await env.DB.prepare(
    `SELECT COALESCE(SUM(net_amount_cents),0) AS v FROM payouts WHERE status = 'paid' AND payout_date BETWEEN ? AND ?`
  ).bind(from, to).first();

  const taxFund = await env.DB.prepare(
    `SELECT COALESCE(SUM(p.tax_withheld_cents),0) AS v
     FROM payouts p JOIN invoices i ON p.invoice_id = i.invoice_id
     WHERE i.paid_date BETWEEN ? AND ?`
  ).bind(from, to).first();

  const badDebt = await env.DB.prepare(
    `SELECT p.payout_id, p.net_amount_cents, p.order_id, s.full_name AS staff_name, o.order_code, c.company_name
     FROM payouts p
     JOIN staff s ON s.staff_id = p.staff_id
     JOIN orders o ON o.order_id = p.order_id
     JOIN clients c ON c.client_id = o.client_id
     WHERE p.case_type = 'bad_debt'`
  ).all();

  return json({
    from, to,
    revenue_received_cents: revenue.v,
    management_fee_cents: mgmtFee.v,
    staff_paid_cents: staffPaid.v,
    tax_fund_cents: taxFund.v,
    net_cashflow_cents: revenue.v - staffPaid.v - taxFund.v,
    bad_debt_list: badDebt.results
  });
}

async function calcPayout(request, env) {
  const { payout_id } = await request.json();
  if (!payout_id) return json({ error: "Thiếu payout_id" }, 400);
  const p = await env.DB.prepare("SELECT * FROM payouts WHERE payout_id = ?").bind(payout_id).first();
  if (!p) return json({ error: "Không tìm thấy payout" }, 404);
  const order = await env.DB.prepare("SELECT * FROM orders WHERE order_id = ?").bind(p.order_id).first();
  const staff = await env.DB.prepare("SELECT * FROM staff WHERE staff_id = ?").bind(p.staff_id).first();
  if (!order || !staff) return json({ error: "Thiếu dữ liệu Đơn hàng hoặc Nhân viên liên quan" }, 400);

  let management_fee_cents = 0, tax_withheld_cents = 0, net_amount_cents = 0;

  if (p.case_type === "client_paid") {
    const gross = p.gross_amount_cents;
    const afterTransferFee = order.fee_payer === "client" ? gross : Math.round(gross * 0.95);
    const feeRate = staff.management_fee_rate / 100;
    const afterMgmtFee = Math.round(afterTransferFee * (1 - feeRate));
    management_fee_cents = afterTransferFee - afterMgmtFee;
    tax_withheld_cents = Math.round(afterMgmtFee * 0.07);
    net_amount_cents = afterMgmtFee - tax_withheld_cents;
  } else if (p.case_type === "bad_debt") {
    const hours = order.estimated_hours || 0;
    net_amount_cents = Math.round(0.5 * hours * staff.avg_hourly_rate_cents);
  } else {
    return json({ error: "case_type không hợp lệ" }, 400);
  }

  await env.DB.prepare(
    `UPDATE payouts SET management_fee_cents = ?, tax_withheld_cents = ?, net_amount_cents = ? WHERE payout_id = ?`
  ).bind(management_fee_cents, tax_withheld_cents, net_amount_cents, payout_id).run();

  return json({ success: true, management_fee_cents, tax_withheld_cents, net_amount_cents });
}
