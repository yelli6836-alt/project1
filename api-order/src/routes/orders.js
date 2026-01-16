const router = require("express").Router();
const crypto = require("crypto");
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");
const { authMiddleware } = require("../utils/authMiddleware");
const { cart: cartCfg } = require("../config");

function makeOrderNumber() {
  const t = Date.now();
  const s = crypto.randomBytes(2).toString("hex").toUpperCase();
  return `ORD-${t}-${s}`;
}

function normalizeItems(items) {
  if (!Array.isArray(items) || !items.length) return null;

  const out = [];
  for (const it of items) {
    const itemId = Number(it.item_id);
    const optionId = it.option_id != null ? Number(it.option_id) : null;
    const skuid = String(it.skuid || "").trim();
    const itemName = String(it.item_name || "").trim();
    const price = Number(it.price_at_purchase);
    const qty = Number(it.qty);

    if (!Number.isFinite(itemId) || itemId <= 0) return null;
    if (optionId != null && (!Number.isFinite(optionId) || optionId <= 0)) return null;
    if (!skuid) return null;
    if (!itemName) return null;
    if (!Number.isFinite(price) || price < 0) return null;
    if (!Number.isFinite(qty) || qty <= 0 || qty > 999) return null;

    out.push({ itemId, optionId, skuid, itemName, price, qty });
  }
  return out;
}

async function createOrderTx(conn, customerId, items) {
  const orderNumber = makeOrderNumber();
  let total = 0;
  for (const it of items) total += it.price * it.qty;

  const [r1] = await conn.query(
    `INSERT INTO orders (order_number, customer_id, order_status, total_amount, receiver_name, shipping_address)
     VALUES (?, ?, 'CREATED', ?, NULL, NULL)`,
    [orderNumber, customerId, total]
  );
  const orderId = r1.insertId;

  const values = items.map((it) => [
    orderId,
    it.itemId,
    it.optionId,
    it.skuid,
    it.itemName,
    it.price,
    it.qty,
  ]);

  await conn.query(
    `INSERT INTO order_items
       (order_id, item_id, option_id, skuid, item_name, price_at_purchase, qty)
     VALUES ?`,
    [values]
  );

  return { order_id: orderId, order_number: orderNumber, total_amount: total };
}

// GET /orders
router.get("/", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const page = Math.max(1, Number(req.query.page || 1));
  const size = Math.min(50, Math.max(1, Number(req.query.size || 20)));
  const offset = (page - 1) * size;

  const [countRows] = await pool.query(
    `SELECT COUNT(*) AS total FROM orders WHERE customer_id=?`,
    [customerId]
  );

  const [rows] = await pool.query(
    `SELECT order_id, order_number, customer_id, order_status, total_amount, created_at, updated_at
       FROM orders
      WHERE customer_id=?
      ORDER BY order_id DESC
      LIMIT ? OFFSET ?`,
    [customerId, size, offset]
  );

  res.json({ ok: true, page, size, total: countRows[0].total, orders: rows });
}));

// GET /orders/:orderNumber
router.get("/:orderNumber", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const orderNumber = String(req.params.orderNumber || "").trim();

  const [orders] = await pool.query(
    `SELECT order_id, order_number, customer_id, order_status, total_amount, receiver_name, shipping_address, created_at, updated_at
       FROM orders
      WHERE order_number=? AND customer_id=?
      LIMIT 1`,
    [orderNumber, customerId]
  );
  if (!orders.length) return res.status(404).json({ ok:false, error:"ORDER_NOT_FOUND" });

  const order = orders[0];
  const [items] = await pool.query(
    `SELECT order_item_id, order_id, item_id, option_id, skuid, item_name, price_at_purchase, qty
       FROM order_items
      WHERE order_id=?
      ORDER BY order_item_id ASC`,
    [order.order_id]
  );

  res.json({ ok:true, order, items });
}));

// POST /orders  (바디로 직접 생성)
router.post("/", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const items = normalizeItems(req.body?.items);
  if (!items) return res.status(400).json({ ok:false, error:"INVALID_ITEMS" });

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const created = await createOrderTx(conn, customerId, items);
    await conn.commit();
    res.status(201).json({ ok:true, order: created });
  } catch (e) {
    try { await conn.rollback(); } catch {}
    throw e;
  } finally {
    conn.release();
  }
}));

// POST /orders/from-cart
router.post("/from-cart", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  if (!cartCfg.baseUrl) return res.status(501).json({ ok:false, error:"CART_API_NOT_CONFIGURED" });

  const auth = req.headers.authorization;

  const cartResp = await fetch(`${cartCfg.baseUrl}/cart`, {
    method: "GET",
    headers: { Authorization: auth },
  });

  if (!cartResp.ok) {
    const txt = await cartResp.text();
    return res.status(502).json({ ok:false, error:"CART_API_ERROR", detail: txt });
  }

  const cartJson = await cartResp.json();
  const cartItems = Array.isArray(cartJson.items) ? cartJson.items : [];
  if (!cartItems.length) return res.status(400).json({ ok:false, error:"CART_EMPTY" });

  // cart_item이 확장되어 skuid/item_name_snapshot이 있어야 정상 흐름
  const items = cartItems.map((it) => ({
    item_id: it.item_id,
    option_id: it.option_id,
    skuid: it.skuid,
    item_name: it.item_name_snapshot,
    price_at_purchase: it.price_snapshot,
    qty: it.qty,
  }));

  const normalized = normalizeItems(items);
  if (!normalized) {
    return res.status(400).json({
      ok:false,
      error:"CART_ITEMS_INVALID",
      message:"cart_item에 skuid/item_name_snapshot이 없거나 값이 비어있음. (cart_db 스키마 확장 필요)"
    });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const created = await createOrderTx(conn, customerId, normalized);
    await conn.commit();

    // cart clear (실패해도 주문은 이미 생성)
    await fetch(`${cartCfg.baseUrl}/cart/clear`, { method:"DELETE", headers:{ Authorization: auth } }).catch(()=>{});

    res.status(201).json({ ok:true, order: created });
  } finally {
    conn.release();
  }
}));

module.exports = router;
