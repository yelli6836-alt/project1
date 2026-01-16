const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");
const { authMiddleware } = require("../utils/authMiddleware");

let schemaCache = null;

// cart_item에 skuid/item_name_snapshot 컬럼이 있는지 자동 감지
async function getCartSchemaFlags() {
  if (schemaCache) return schemaCache;

  const [cols] = await pool.query(
    `SELECT COLUMN_NAME
       FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'cart_item'
        AND COLUMN_NAME IN ('skuid','item_name_snapshot')`
  );

  const set = new Set(cols.map((r) => r.COLUMN_NAME));
  schemaCache = {
    hasSkuid: set.has("skuid"),
    hasItemNameSnapshot: set.has("item_name_snapshot"),
  };
  return schemaCache;
}

async function ensureCart(conn, customerId) {
  const [rows] = await conn.query(
    `SELECT cart_id FROM cart WHERE customer_id=? LIMIT 1`,
    [customerId]
  );
  if (rows.length) return rows[0].cart_id;

  const [r] = await conn.query(`INSERT INTO cart (customer_id) VALUES (?)`, [customerId]);
  return r.insertId;
}

// GET /cart
router.get("/", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const flags = await getCartSchemaFlags();

  const conn = await pool.getConnection();
  try {
    const cartId = await ensureCart(conn, customerId);

    const selectCols = [
      "cart_item_id","cart_id","item_id","option_id","qty","price_snapshot","created_at","updated_at"
    ];
    if (flags.hasSkuid) selectCols.push("skuid");
    if (flags.hasItemNameSnapshot) selectCols.push("item_name_snapshot");

    const [items] = await conn.query(
      `SELECT ${selectCols.join(", ")}
         FROM cart_item
        WHERE cart_id=?
        ORDER BY cart_item_id DESC`,
      [cartId]
    );

    res.json({ ok: true, cart: { cart_id: cartId, customer_id: customerId }, items });
  } finally {
    conn.release();
  }
}));

// POST /cart/items
router.post("/items", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const flags = await getCartSchemaFlags();

  const itemId = Number(req.body.item_id);
  const optionId = Number(req.body.option_id);
  const qty = Number(req.body.qty || 1);
  const priceSnapshot = req.body.price_snapshot != null ? Number(req.body.price_snapshot) : 0;

  const skuid = req.body.skuid != null ? String(req.body.skuid).trim() : null;
  const itemNameSnapshot = req.body.item_name_snapshot != null ? String(req.body.item_name_snapshot).trim() : null;

  if (!Number.isFinite(itemId) || itemId <= 0) return res.status(400).json({ ok:false, error:"INVALID_ITEM_ID" });
  if (!Number.isFinite(optionId) || optionId <= 0) return res.status(400).json({ ok:false, error:"INVALID_OPTION_ID" });
  if (!Number.isFinite(qty) || qty <= 0 || qty > 999) return res.status(400).json({ ok:false, error:"INVALID_QTY" });
  if (!Number.isFinite(priceSnapshot) || priceSnapshot < 0) return res.status(400).json({ ok:false, error:"INVALID_PRICE_SNAPSHOT" });

  // 스키마가 확장된 경우에는 skuid/item_name_snapshot을 강제
  if (flags.hasSkuid && (!skuid || skuid.length > 50)) {
    return res.status(400).json({ ok:false, error:"SKUID_REQUIRED" });
  }
  if (flags.hasItemNameSnapshot && (!itemNameSnapshot || itemNameSnapshot.length > 255)) {
    return res.status(400).json({ ok:false, error:"ITEM_NAME_SNAPSHOT_REQUIRED" });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const cartId = await ensureCart(conn, customerId);

    if (flags.hasSkuid && flags.hasItemNameSnapshot) {
      await conn.query(
        `INSERT INTO cart_item (cart_id, item_id, option_id, qty, price_snapshot, skuid, item_name_snapshot)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE
           qty = qty + VALUES(qty),
           price_snapshot = VALUES(price_snapshot),
           skuid = VALUES(skuid),
           item_name_snapshot = VALUES(item_name_snapshot),
           updated_at = CURRENT_TIMESTAMP`,
        [cartId, itemId, optionId, qty, priceSnapshot, skuid, itemNameSnapshot]
      );
    } else {
      await conn.query(
        `INSERT INTO cart_item (cart_id, item_id, option_id, qty, price_snapshot)
         VALUES (?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE
           qty = qty + VALUES(qty),
           price_snapshot = VALUES(price_snapshot),
           updated_at = CURRENT_TIMESTAMP`,
        [cartId, itemId, optionId, qty, priceSnapshot]
      );
    }

    await conn.commit();
    res.status(201).json({ ok: true, added: true });
  } catch (e) {
    try { await conn.rollback(); } catch {}
    throw e;
  } finally {
    conn.release();
  }
}));

// PATCH /cart/items/:cartItemId  { qty } (0이면 삭제)
router.patch("/items/:cartItemId", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const cartItemId = Number(req.params.cartItemId);
  const qty = Number(req.body.qty);

  if (!Number.isFinite(cartItemId) || cartItemId <= 0) return res.status(400).json({ ok:false, error:"INVALID_CART_ITEM_ID" });
  if (!Number.isFinite(qty) || qty < 0 || qty > 999) return res.status(400).json({ ok:false, error:"INVALID_QTY" });

  if (qty === 0) {
    const [del] = await pool.query(
      `DELETE ci
         FROM cart_item ci
         JOIN cart c ON c.cart_id = ci.cart_id
        WHERE ci.cart_item_id = ?
          AND c.customer_id = ?`,
      [cartItemId, customerId]
    );
    if (!del.affectedRows) return res.status(404).json({ ok:false, error:"ITEM_NOT_FOUND" });
    return res.json({ ok:true, deleted:true });
  }

  const [upd] = await pool.query(
    `UPDATE cart_item ci
      JOIN cart c ON c.cart_id = ci.cart_id
       SET ci.qty = ?, ci.updated_at = CURRENT_TIMESTAMP
     WHERE ci.cart_item_id = ?
       AND c.customer_id = ?`,
    [qty, cartItemId, customerId]
  );
  if (!upd.affectedRows) return res.status(404).json({ ok:false, error:"ITEM_NOT_FOUND" });

  res.json({ ok:true, updated:true });
}));

router.delete("/items/:cartItemId", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const cartItemId = Number(req.params.cartItemId);
  if (!Number.isFinite(cartItemId) || cartItemId <= 0) {
    return res.status(400).json({ ok:false, error:"INVALID_CART_ITEM_ID" });
  }

  const [del] = await pool.query(
    `DELETE ci
       FROM cart_item ci
       JOIN cart c ON c.cart_id = ci.cart_id
      WHERE ci.cart_item_id = ?
        AND c.customer_id = ?`,
    [cartItemId, customerId]
  );
  if (!del.affectedRows) return res.status(404).json({ ok:false, error:"ITEM_NOT_FOUND" });

  res.json({ ok:true, deleted:true });
}));

router.delete("/clear", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const conn = await pool.getConnection();
  try {
    const cartId = await ensureCart(conn, customerId);
    await conn.query(`DELETE FROM cart_item WHERE cart_id=?`, [cartId]);
    res.json({ ok:true, cleared:true, cart_id: cartId });
  } finally {
    conn.release();
  }
}));

module.exports = router;
