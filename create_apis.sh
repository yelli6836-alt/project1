#!/usr/bin/env bash
set -euo pipefail

ROOT="/srv/mall-apis"
mkdir -p "$ROOT"

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOT'
'"$@"'
EOT
}

# -----------------------------------------
# 공통: .dockerignore (각 서비스)
# -----------------------------------------
make_dockerignore() {
  cat > "$1" <<'EOT'
node_modules
npm-debug.log
.env
.env.*
.git
EOT
}

# -----------------------------------------
# api-product
# -----------------------------------------
mkdir -p "$ROOT/api-product/src/routes" "$ROOT/api-product/src/utils"
make_dockerignore "$ROOT/api-product/.dockerignore"

cat > "$ROOT/api-product/package.json" <<'EOT'
{
  "name": "api-product",
  "version": "1.0.0",
  "main": "src/server.js",
  "type": "commonjs",
  "scripts": {
    "start": "node src/server.js"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "morgan": "^1.10.0",
    "mysql2": "^3.11.0"
  }
}
EOT

cat > "$ROOT/api-product/Dockerfile" <<'EOT'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src
EXPOSE 3005
CMD ["node","src/server.js"]
EOT

cat > "$ROOT/api-product/.env" <<'EOT'
PORT=3005
DB_HOST=YOUR_DB_HOST
DB_PORT=3306
DB_USER=product_user
DB_PASS=Product!1234
DB_NAME=product_db
DB_POOL_LIMIT=10
EOT

cat > "$ROOT/api-product/src/config.js" <<'EOT'
require("dotenv").config();

function must(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

module.exports = {
  port: Number(process.env.PORT || 3005),
  db: {
    host: must("DB_HOST"),
    port: Number(process.env.DB_PORT || 3306),
    user: must("DB_USER"),
    password: must("DB_PASS"),
    database: must("DB_NAME"),
    connectionLimit: Number(process.env.DB_POOL_LIMIT || 10),
  },
};
EOT

cat > "$ROOT/api-product/src/db.js" <<'EOT'
const mysql = require("mysql2/promise");
const { db } = require("./config");

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: db.connectionLimit,
  namedPlaceholders: true,
});

module.exports = { pool };
EOT

cat > "$ROOT/api-product/src/utils/asyncWrap.js" <<'EOT'
module.exports = function asyncWrap(fn) {
  return function wrapped(req, res, next) {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
};
EOT

cat > "$ROOT/api-product/src/routes/health.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  await pool.query("SELECT 1");
  res.json({ ok: true, service: "api-product" });
}));

module.exports = router;
EOT

cat > "$ROOT/api-product/src/routes/categories.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  const [rows] = await pool.query(
    `SELECT category_id, category_name
       FROM category
      ORDER BY category_id ASC`
  );
  res.json({ ok: true, categories: rows });
}));

module.exports = router;
EOT

cat > "$ROOT/api-product/src/routes/products.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

// GET /products?category_id=&q=&page=&size=&status=
router.get("/", asyncWrap(async (req, res) => {
  const categoryId = req.query.category_id ? Number(req.query.category_id) : null;
  const q = req.query.q ? String(req.query.q).trim() : null;
  const status = req.query.status ? String(req.query.status).trim() : null;

  const page = Math.max(1, Number(req.query.page || 1));
  const size = Math.min(50, Math.max(1, Number(req.query.size || 20)));
  const offset = (page - 1) * size;

  const where = [];
  const params = { limit: size, offset };

  if (categoryId) {
    where.push("i.category_id = :categoryId");
    params.categoryId = categoryId;
  }
  if (status) {
    // status ENUM('판매중','판매중지')
    where.push("i.status = :status");
    params.status = status;
  }
  if (q) {
    where.push("MATCH(i.item_name, i.item_desc) AGAINST(:q IN BOOLEAN MODE)");
    params.q = q + "*";
  }

  const whereSql = where.length ? `WHERE ${where.join(" AND ")}` : "";

  const [countRows] = await pool.query(
    `SELECT COUNT(*) AS total
       FROM item i
       ${whereSql}`,
    params
  );

  const [rows] = await pool.query(
    `SELECT
       i.item_id, i.category_id, i.item_name, i.base_cost, i.status, i.created_at,
       c.category_name
     FROM item i
     JOIN category c ON c.category_id = i.category_id
     ${whereSql}
     ORDER BY i.item_id DESC
     LIMIT :limit OFFSET :offset`,
    params
  );

  res.json({ ok: true, page, size, total: countRows[0].total, items: rows });
}));

router.get("/:itemId", asyncWrap(async (req, res) => {
  const itemId = Number(req.params.itemId);

  const [rows] = await pool.query(
    `SELECT i.item_id, i.category_id, i.item_name, i.base_cost, i.item_desc, i.status, i.created_at,
            c.category_name
       FROM item i
       JOIN category c ON c.category_id = i.category_id
      WHERE i.item_id = ?`,
    [itemId]
  );

  if (!rows.length) return res.status(404).json({ ok: false, error: "ITEM_NOT_FOUND" });
  res.json({ ok: true, item: rows[0] });
}));

router.get("/:itemId/images", asyncWrap(async (req, res) => {
  const itemId = Number(req.params.itemId);

  const [rows] = await pool.query(
    `SELECT image_id, item_id, url, display_order, created_at
       FROM item_image
      WHERE item_id = ?
      ORDER BY display_order IS NULL, display_order ASC, image_id ASC`,
    [itemId]
  );

  res.json({ ok: true, images: rows });
}));

router.get("/:itemId/options", asyncWrap(async (req, res) => {
  const itemId = Number(req.params.itemId);

  const [rows] = await pool.query(
    `SELECT option_id, item_id, skuid, option_name, option_value, add_cost, created_at
       FROM item_option
      WHERE item_id = ?
      ORDER BY option_id ASC`,
    [itemId]
  );

  res.json({ ok: true, options: rows });
}));

module.exports = router;
EOT

cat > "$ROOT/api-product/src/app.js" <<'EOT'
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");

const health = require("./routes/health");
const categories = require("./routes/categories");
const products = require("./routes/products");

const app = express();

app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(morgan("dev"));

app.use("/health", health);
app.use("/categories", categories);
app.use("/products", products);

app.use((req, res) => res.status(404).json({ ok: false, error: "NOT_FOUND" }));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ ok: false, error: "INTERNAL_ERROR", message: err.message });
});

module.exports = { app };
EOT

cat > "$ROOT/api-product/src/server.js" <<'EOT'
const { app } = require("./app");
const { port } = require("./config");
const { pool } = require("./db");

async function start() {
  await pool.query("SELECT 1");
  app.listen(port, "0.0.0.0", () => {
    console.log(`[api-product] listening on :${port}`);
  });
}

start().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
EOT

# -----------------------------------------
# api-customer
# -----------------------------------------
mkdir -p "$ROOT/api-customer/src/routes" "$ROOT/api-customer/src/utils"
make_dockerignore "$ROOT/api-customer/.dockerignore"

cat > "$ROOT/api-customer/package.json" <<'EOT'
{
  "name": "api-customer",
  "version": "1.0.0",
  "main": "src/server.js",
  "type": "commonjs",
  "scripts": { "start": "node src/server.js" },
  "dependencies": {
    "bcrypt": "^5.1.1",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "jsonwebtoken": "^9.0.2",
    "morgan": "^1.10.0",
    "mysql2": "^3.11.0"
  }
}
EOT

cat > "$ROOT/api-customer/Dockerfile" <<'EOT'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src
EXPOSE 3006
CMD ["node","src/server.js"]
EOT

cat > "$ROOT/api-customer/.env" <<'EOT'
PORT=3006
DB_HOST=YOUR_DB_HOST
DB_PORT=3306
DB_USER=customer_user
DB_PASS=Customer!1234
DB_NAME=customer_db
DB_POOL_LIMIT=10
JWT_SECRET=ChangeMe_SuperSecret
JWT_EXPIRES_IN=2h
EOT

cat > "$ROOT/api-customer/src/config.js" <<'EOT'
require("dotenv").config();
function must(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}
module.exports = {
  port: Number(process.env.PORT || 3006),
  db: {
    host: must("DB_HOST"),
    port: Number(process.env.DB_PORT || 3306),
    user: must("DB_USER"),
    password: must("DB_PASS"),
    database: must("DB_NAME"),
    connectionLimit: Number(process.env.DB_POOL_LIMIT || 10),
  },
  jwt: {
    secret: must("JWT_SECRET"),
    expiresIn: process.env.JWT_EXPIRES_IN || "2h",
  },
};
EOT

cat > "$ROOT/api-customer/src/db.js" <<'EOT'
const mysql = require("mysql2/promise");
const { db } = require("./config");

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: db.connectionLimit,
  namedPlaceholders: true,
});

module.exports = { pool };
EOT

cat > "$ROOT/api-customer/src/utils/asyncWrap.js" <<'EOT'
module.exports = function asyncWrap(fn) {
  return function wrapped(req, res, next) {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
};
EOT

cat > "$ROOT/api-customer/src/utils/authMiddleware.js" <<'EOT'
const jwt = require("jsonwebtoken");
const { jwt: jwtCfg } = require("../config");

function authMiddleware(req, res, next) {
  const h = req.headers.authorization || "";
  const [type, token] = h.split(" ");
  if (type !== "Bearer" || !token) {
    return res.status(401).json({ ok: false, error: "NO_TOKEN" });
  }
  try {
    const payload = jwt.verify(token, jwtCfg.secret);
    req.user = payload; // { customer_id, email }
    return next();
  } catch {
    return res.status(401).json({ ok: false, error: "INVALID_TOKEN" });
  }
}

module.exports = { authMiddleware };
EOT

cat > "$ROOT/api-customer/src/routes/health.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  await pool.query("SELECT 1");
  res.json({ ok: true, service: "api-customer" });
}));

module.exports = router;
EOT

cat > "$ROOT/api-customer/src/routes/auth.js" <<'EOT'
const router = require("express").Router();
const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");
const { jwt: jwtCfg } = require("../config");

// POST /auth/register
router.post("/register", asyncWrap(async (req, res) => {
  const email = String(req.body.email || "").trim().toLowerCase();
  const name = String(req.body.name || "").trim();
  const password = String(req.body.password || "");

  if (!email || !name || password.length < 6) {
    return res.status(400).json({ ok: false, error: "INVALID_INPUT" });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [exists] = await conn.query(
      "SELECT customer_id FROM customers WHERE customer_email = ? LIMIT 1",
      [email]
    );
    if (exists.length) {
      await conn.rollback();
      return res.status(409).json({ ok: false, error: "EMAIL_ALREADY_EXISTS" });
    }

    const [r1] = await conn.query(
      "INSERT INTO customers (customer_email, customer_name) VALUES (?, ?)",
      [email, name]
    );
    const customerId = r1.insertId;

    const passwordHash = await bcrypt.hash(password, 12);
    await conn.query(
      "INSERT INTO customer_auth (customer_id, password_hash) VALUES (?, ?)",
      [customerId, passwordHash]
    );

    await conn.commit();

    res.status(201).json({
      ok: true,
      customer: { customer_id: customerId, customer_email: email, customer_name: name },
    });
  } catch (e) {
    try { await conn.rollback(); } catch {}
    throw e;
  } finally {
    conn.release();
  }
}));

// POST /auth/login
router.post("/login", asyncWrap(async (req, res) => {
  const email = String(req.body.email || "").trim().toLowerCase();
  const password = String(req.body.password || "");

  if (!email || !password) {
    return res.status(400).json({ ok: false, error: "INVALID_INPUT" });
  }

  const [rows] = await pool.query(
    `SELECT c.customer_id, c.customer_email, c.customer_name, a.password_hash
       FROM customers c
       JOIN customer_auth a ON a.customer_id = c.customer_id
      WHERE c.customer_email = ?
      LIMIT 1`,
    [email]
  );

  if (!rows.length) return res.status(401).json({ ok: false, error: "INVALID_CREDENTIALS" });

  const u = rows[0];
  const ok = await bcrypt.compare(password, u.password_hash);
  if (!ok) return res.status(401).json({ ok: false, error: "INVALID_CREDENTIALS" });

  const token = jwt.sign(
    { customer_id: u.customer_id, email: u.customer_email },
    jwtCfg.secret,
    { expiresIn: jwtCfg.expiresIn }
  );

  res.json({
    ok: true,
    token,
    customer: {
      customer_id: u.customer_id,
      customer_email: u.customer_email,
      customer_name: u.customer_name,
    },
  });
}));

router.post("/logout", (req, res) => {
  res.json({ ok: true, message: "client_should_delete_token" });
});

module.exports = router;
EOT

cat > "$ROOT/api-customer/src/routes/me.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");
const { authMiddleware } = require("../utils/authMiddleware");

router.get("/", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;

  const [rows] = await pool.query(
    "SELECT customer_id, customer_email, customer_name, created_at FROM customers WHERE customer_id = ?",
    [customerId]
  );

  if (!rows.length) return res.status(404).json({ ok: false, error: "USER_NOT_FOUND" });
  res.json({ ok: true, me: rows[0] });
}));

module.exports = router;
EOT

cat > "$ROOT/api-customer/src/app.js" <<'EOT'
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");

const health = require("./routes/health");
const auth = require("./routes/auth");
const me = require("./routes/me");

const app = express();

app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(morgan("dev"));

app.use("/health", health);
app.use("/auth", auth);
app.use("/me", me);

app.use((req, res) => res.status(404).json({ ok: false, error: "NOT_FOUND" }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ ok: false, error: "INTERNAL_ERROR", message: err.message });
});

module.exports = { app };
EOT

cat > "$ROOT/api-customer/src/server.js" <<'EOT'
const { app } = require("./app");
const { port } = require("./config");
const { pool } = require("./db");

async function start() {
  await pool.query("SELECT 1");
  app.listen(port, "0.0.0.0", () => console.log(`[api-customer] listening on :${port}`));
}

start().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
EOT

# -----------------------------------------
# api-cart  (cart_item에 skuid/item_name_snapshot 컬럼이 있으면 같이 쓰고,
#            없으면 기본 스키마로도 동작은 하되 from-cart에선 skuid 없으면 실패하게 설계)
# -----------------------------------------
mkdir -p "$ROOT/api-cart/src/routes" "$ROOT/api-cart/src/utils"
make_dockerignore "$ROOT/api-cart/.dockerignore"

cat > "$ROOT/api-cart/package.json" <<'EOT'
{
  "name": "api-cart",
  "version": "1.0.0",
  "main": "src/server.js",
  "type": "commonjs",
  "scripts": { "start": "node src/server.js" },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "jsonwebtoken": "^9.0.2",
    "morgan": "^1.10.0",
    "mysql2": "^3.11.0"
  }
}
EOT

cat > "$ROOT/api-cart/Dockerfile" <<'EOT'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src
EXPOSE 3007
CMD ["node","src/server.js"]
EOT

cat > "$ROOT/api-cart/.env" <<'EOT'
PORT=3007
DB_HOST=YOUR_DB_HOST
DB_PORT=3306
DB_USER=cart_user
DB_PASS=Cart!1234
DB_NAME=cart_db
DB_POOL_LIMIT=10
JWT_SECRET=ChangeMe_SuperSecret
EOT

cat > "$ROOT/api-cart/src/config.js" <<'EOT'
require("dotenv").config();
function must(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}
module.exports = {
  port: Number(process.env.PORT || 3007),
  db: {
    host: must("DB_HOST"),
    port: Number(process.env.DB_PORT || 3306),
    user: must("DB_USER"),
    password: must("DB_PASS"),
    database: must("DB_NAME"),
    connectionLimit: Number(process.env.DB_POOL_LIMIT || 10),
  },
  jwt: { secret: must("JWT_SECRET") },
};
EOT

cat > "$ROOT/api-cart/src/db.js" <<'EOT'
const mysql = require("mysql2/promise");
const { db } = require("./config");

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: db.connectionLimit,
  namedPlaceholders: true,
});

module.exports = { pool };
EOT

cat > "$ROOT/api-cart/src/utils/asyncWrap.js" <<'EOT'
module.exports = function asyncWrap(fn) {
  return function wrapped(req, res, next) {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
};
EOT

cat > "$ROOT/api-cart/src/utils/authMiddleware.js" <<'EOT'
const jwt = require("jsonwebtoken");
const { jwt: jwtCfg } = require("../config");

function authMiddleware(req, res, next) {
  const h = req.headers.authorization || "";
  const [type, token] = h.split(" ");
  if (type !== "Bearer" || !token) return res.status(401).json({ ok: false, error: "NO_TOKEN" });
  try {
    req.user = jwt.verify(token, jwtCfg.secret);
    return next();
  } catch {
    return res.status(401).json({ ok: false, error: "INVALID_TOKEN" });
  }
}

module.exports = { authMiddleware };
EOT

cat > "$ROOT/api-cart/src/routes/health.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  await pool.query("SELECT 1");
  res.json({ ok: true, service: "api-cart" });
}));

module.exports = router;
EOT

cat > "$ROOT/api-cart/src/routes/wishlist.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");
const { authMiddleware } = require("../utils/authMiddleware");

router.get("/", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const [rows] = await pool.query(
    `SELECT wishlist_id, customer_id, item_id, created_at
       FROM wishlist
      WHERE customer_id = ?
      ORDER BY wishlist_id DESC`,
    [customerId]
  );
  res.json({ ok: true, items: rows });
}));

router.post("/", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const itemId = Number(req.body.item_id);
  if (!Number.isFinite(itemId) || itemId <= 0) {
    return res.status(400).json({ ok: false, error: "INVALID_ITEM_ID" });
  }

  await pool.query(
    `INSERT INTO wishlist (customer_id, item_id)
     VALUES (?, ?)
     ON DUPLICATE KEY UPDATE created_at = created_at`,
    [customerId, itemId]
  );

  res.status(201).json({ ok: true, added: true, item_id: itemId });
}));

router.delete("/:itemId", authMiddleware, asyncWrap(async (req, res) => {
  const customerId = req.user.customer_id;
  const itemId = Number(req.params.itemId);
  if (!Number.isFinite(itemId) || itemId <= 0) {
    return res.status(400).json({ ok: false, error: "INVALID_ITEM_ID" });
  }

  const [del] = await pool.query(
    `DELETE FROM wishlist WHERE customer_id=? AND item_id=?`,
    [customerId, itemId]
  );
  if (!del.affectedRows) return res.status(404).json({ ok: false, error: "NOT_FOUND" });

  res.json({ ok: true, deleted: true });
}));

module.exports = router;
EOT

cat > "$ROOT/api-cart/src/routes/cart.js" <<'EOT'
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
EOT

cat > "$ROOT/api-cart/src/app.js" <<'EOT'
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");

const health = require("./routes/health");
const cart = require("./routes/cart");
const wishlist = require("./routes/wishlist");

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(morgan("dev"));

app.use("/health", health);
app.use("/cart", cart);
app.use("/wishlist", wishlist);

app.use((req, res) => res.status(404).json({ ok: false, error: "NOT_FOUND" }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ ok: false, error: "INTERNAL_ERROR", message: err.message });
});

module.exports = { app };
EOT

cat > "$ROOT/api-cart/src/server.js" <<'EOT'
const { app } = require("./app");
const { port } = require("./config");
const { pool } = require("./db");

async function start() {
  await pool.query("SELECT 1");
  app.listen(port, "0.0.0.0", () => console.log(`[api-cart] listening on :${port}`));
}

start().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
EOT

# -----------------------------------------
# api-order (payment_db의 orders/order_items 스키마에 맞춤)
# -----------------------------------------
mkdir -p "$ROOT/api-order/src/routes" "$ROOT/api-order/src/utils"
make_dockerignore "$ROOT/api-order/.dockerignore"

cat > "$ROOT/api-order/package.json" <<'EOT'
{
  "name": "api-order",
  "version": "1.0.0",
  "main": "src/server.js",
  "type": "commonjs",
  "scripts": { "start": "node src/server.js" },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "jsonwebtoken": "^9.0.2",
    "morgan": "^1.10.0",
    "mysql2": "^3.11.0"
  }
}
EOT

cat > "$ROOT/api-order/Dockerfile" <<'EOT'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src
EXPOSE 3008
CMD ["node","src/server.js"]
EOT

cat > "$ROOT/api-order/.env" <<'EOT'
PORT=3008
DB_HOST=YOUR_DB_HOST
DB_PORT=3306
DB_USER=order_user
DB_PASS=Order!1234
DB_NAME=payment_db
DB_POOL_LIMIT=10
JWT_SECRET=ChangeMe_SuperSecret
CART_API_BASE=http://api-cart:3007
EOT

cat > "$ROOT/api-order/src/config.js" <<'EOT'
require("dotenv").config();
function must(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}
module.exports = {
  port: Number(process.env.PORT || 3008),
  db: {
    host: must("DB_HOST"),
    port: Number(process.env.DB_PORT || 3306),
    user: must("DB_USER"),
    password: must("DB_PASS"),
    database: must("DB_NAME"),
    connectionLimit: Number(process.env.DB_POOL_LIMIT || 10),
  },
  jwt: { secret: must("JWT_SECRET") },
  cart: { baseUrl: process.env.CART_API_BASE || "" },
};
EOT

cat > "$ROOT/api-order/src/db.js" <<'EOT'
const mysql = require("mysql2/promise");
const { db } = require("./config");

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: db.connectionLimit,
  namedPlaceholders: true,
});

module.exports = { pool };
EOT

cat > "$ROOT/api-order/src/utils/asyncWrap.js" <<'EOT'
module.exports = function asyncWrap(fn) {
  return function wrapped(req, res, next) {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
};
EOT

cat > "$ROOT/api-order/src/utils/authMiddleware.js" <<'EOT'
const jwt = require("jsonwebtoken");
const { jwt: jwtCfg } = require("../config");

function authMiddleware(req, res, next) {
  const h = req.headers.authorization || "";
  const [type, token] = h.split(" ");
  if (type !== "Bearer" || !token) return res.status(401).json({ ok: false, error: "NO_TOKEN" });
  try {
    req.user = jwt.verify(token, jwtCfg.secret);
    return next();
  } catch {
    return res.status(401).json({ ok: false, error: "INVALID_TOKEN" });
  }
}

module.exports = { authMiddleware };
EOT

cat > "$ROOT/api-order/src/routes/health.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  await pool.query("SELECT 1");
  res.json({ ok: true, service: "api-order" });
}));

module.exports = router;
EOT

cat > "$ROOT/api-order/src/routes/orders.js" <<'EOT'
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
EOT

cat > "$ROOT/api-order/src/app.js" <<'EOT'
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");

const health = require("./routes/health");
const orders = require("./routes/orders");

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(morgan("dev"));

app.use("/health", health);
app.use("/orders", orders);

app.use((req, res) => res.status(404).json({ ok:false, error:"NOT_FOUND" }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ ok:false, error:"INTERNAL_ERROR", message: err.message });
});

module.exports = { app };
EOT

cat > "$ROOT/api-order/src/server.js" <<'EOT'
const { app } = require("./app");
const { port } = require("./config");
const { pool } = require("./db");

async function start() {
  await pool.query("SELECT 1");
  app.listen(port, "0.0.0.0", () => console.log(`[api-order] listening on :${port}`));
}

start().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
EOT

# -----------------------------------------
# api-payment
# -----------------------------------------
mkdir -p "$ROOT/api-payment/src/routes" "$ROOT/api-payment/src/controllers" "$ROOT/api-payment/src/utils"
make_dockerignore "$ROOT/api-payment/.dockerignore"

cat > "$ROOT/api-payment/package.json" <<'EOT'
{
  "name": "api-payment",
  "version": "1.0.0",
  "main": "src/server.js",
  "type": "commonjs",
  "scripts": { "start": "node src/server.js" },
  "dependencies": {
    "amqplib": "^0.10.4",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "morgan": "^1.10.0",
    "mysql2": "^3.11.0"
  }
}
EOT

cat > "$ROOT/api-payment/Dockerfile" <<'EOT'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src
EXPOSE 3001
CMD ["node","src/server.js"]
EOT

cat > "$ROOT/api-payment/.env" <<'EOT'
PORT=3001
DB_HOST=YOUR_DB_HOST
DB_PORT=3306
DB_USER=payment_user
DB_PASS=Payment!1234
DB_NAME=payment_db
DB_POOL_LIMIT=10

RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672
RABBITMQ_EXCHANGE=mall.events
EOT

cat > "$ROOT/api-payment/src/config.js" <<'EOT'
require("dotenv").config();
function must(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}
module.exports = {
  port: Number(process.env.PORT || 3001),
  db: {
    host: must("DB_HOST"),
    port: Number(process.env.DB_PORT || 3306),
    user: must("DB_USER"),
    password: must("DB_PASS"),
    database: must("DB_NAME"),
    connectionLimit: Number(process.env.DB_POOL_LIMIT || 10),
  },
  rabbit: {
    url: must("RABBITMQ_URL"),
    exchange: must("RABBITMQ_EXCHANGE"),
  },
};
EOT

cat > "$ROOT/api-payment/src/db.js" <<'EOT'
const mysql = require("mysql2/promise");
const { db } = require("./config");

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: db.connectionLimit,
  namedPlaceholders: true,
});

module.exports = { pool };
EOT

cat > "$ROOT/api-payment/src/utils/asyncWrap.js" <<'EOT'
module.exports = function asyncWrap(fn) {
  return function wrapped(req, res, next) {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
};
EOT

cat > "$ROOT/api-payment/src/rabbit.js" <<'EOT'
const amqp = require("amqplib");
const { rabbit } = require("./config");

let conn = null;
let ch = null;

async function getChannel() {
  if (ch) return ch;
  conn = await amqp.connect(rabbit.url);
  ch = await conn.createChannel();
  await ch.assertExchange(rabbit.exchange, "topic", { durable: true });
  return ch;
}

async function publish(routingKey, payload) {
  const channel = await getChannel();
  channel.publish(
    rabbit.exchange,
    routingKey,
    Buffer.from(JSON.stringify(payload)),
    { persistent: true }
  );
}

module.exports = { publish };
EOT

cat > "$ROOT/api-payment/src/routes/health.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  await pool.query("SELECT 1");
  res.json({ ok: true, service: "api-payment" });
}));

module.exports = router;
EOT

cat > "$ROOT/api-payment/src/controllers/payments.controller.js" <<'EOT'
const { pool } = require("../db");
const rabbit = require("../rabbit");
const { randomUUID } = require("crypto");

async function pingDb(req, res) {
  const [rows] = await pool.query("SELECT DATABASE() AS db, NOW() AS now");
  res.json({ ok: true, ...rows[0] });
}

async function testPublish(req, res) {
  const event = {
    eventId: randomUUID(),
    occurredAt: new Date().toISOString(),
    type: "payment.order.paid",
    data: {
      orderNumber: "ORD-TEST-0001",
      customerId: 1,
      items: [{ skuid: "SKU-00000001-01", qty: 1 }],
      totalAmount: 12000,
    },
  };
  await rabbit.publish("payment.order.paid", event);
  res.json({ ok: true, published: true });
}

async function approve(req, res) {
  const orderNumber = String(req.body.orderNumber || "").trim();
  const provider = String(req.body.provider || "mockpay").trim();
  if (!orderNumber) return res.status(400).json({ ok: false, error: "ORDER_NUMBER_REQUIRED" });

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [orderRows] = await conn.query(
      `SELECT order_id, order_number, customer_id, order_status, total_amount
         FROM orders
        WHERE order_number = ? FOR UPDATE`,
      [orderNumber]
    );
    if (!orderRows.length) {
      await conn.rollback();
      return res.status(404).json({ ok: false, error: "ORDER_NOT_FOUND" });
    }
    const order = orderRows[0];

    if (order.order_status === "PAID") {
      await conn.commit();
      return res.json({ ok: true, alreadyPaid: true, orderNumber });
    }

    await conn.query(
      `INSERT INTO payments (order_id, customer_id, pay_status, amount, provider, approved_at)
       VALUES (?, ?, 'APPROVED', ?, ?, NOW())`,
      [order.order_id, order.customer_id, order.total_amount, provider]
    );

    await conn.query(
      `UPDATE orders SET order_status='PAID' WHERE order_id=?`,
      [order.order_id]
    );

    await conn.commit();

    const [itemRows] = await pool.query(
      `SELECT skuid, qty
         FROM order_items
        WHERE order_id = ?
        ORDER BY order_item_id ASC`,
      [order.order_id]
    );

    const event = {
      eventId: randomUUID(),
      occurredAt: new Date().toISOString(),
      type: "payment.order.paid",
      data: {
        orderNumber: order.order_number,
        customerId: order.customer_id,
        items: itemRows.map((r) => ({ skuid: r.skuid, qty: r.qty })),
        totalAmount: Number(order.total_amount),
      },
    };

    await rabbit.publish("payment.order.paid", event);

    res.json({ ok: true, orderNumber: order.order_number, published: true, eventId: event.eventId });
  } catch (e) {
    try { await conn.rollback(); } catch {}
    throw e;
  } finally {
    conn.release();
  }
}

module.exports = { pingDb, testPublish, approve };
EOT

cat > "$ROOT/api-payment/src/routes/payments.js" <<'EOT'
const router = require("express").Router();
const asyncWrap = require("../utils/asyncWrap");
const ctrl = require("../controllers/payments.controller");

router.get("/ping-db", asyncWrap(ctrl.pingDb));
router.post("/test-publish", asyncWrap(ctrl.testPublish));
router.post("/approve", asyncWrap(ctrl.approve));

module.exports = router;
EOT

cat > "$ROOT/api-payment/src/app.js" <<'EOT'
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");

const health = require("./routes/health");
const payments = require("./routes/payments");

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(morgan("dev"));

app.use("/health", health);
app.use("/payments", payments);

app.use((req, res) => res.status(404).json({ ok:false, error:"NOT_FOUND" }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ ok:false, error:"INTERNAL_ERROR", message: err.message });
});

module.exports = { app };
EOT

cat > "$ROOT/api-payment/src/server.js" <<'EOT'
const { app } = require("./app");
const { port } = require("./config");
const { pool } = require("./db");

async function start() {
  await pool.query("SELECT 1");
  app.listen(port, "0.0.0.0", () => console.log(`[api-payment] listening on :${port}`));
}

start().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
EOT

# -----------------------------------------
# api-delivery (HTTP + consumer 분리 실행)
# -----------------------------------------
mkdir -p "$ROOT/api-delivery/src/routes" "$ROOT/api-delivery/src/controllers" "$ROOT/api-delivery/src/utils"
make_dockerignore "$ROOT/api-delivery/.dockerignore"

cat > "$ROOT/api-delivery/package.json" <<'EOT'
{
  "name": "api-delivery",
  "version": "1.0.0",
  "main": "src/server.js",
  "type": "commonjs",
  "scripts": {
    "start": "node src/server.js",
    "consumer": "node src/consumer.js"
  },
  "dependencies": {
    "amqplib": "^0.10.4",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "morgan": "^1.10.0",
    "mysql2": "^3.11.0"
  }
}
EOT

cat > "$ROOT/api-delivery/Dockerfile" <<'EOT'
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src
EXPOSE 3003
CMD ["node","src/server.js"]
EOT

cat > "$ROOT/api-delivery/.env" <<'EOT'
PORT=3003
DB_HOST=YOUR_DB_HOST
DB_PORT=3306
DB_USER=delivery_user
DB_PASS=Delivery!1234
DB_NAME=delivery_db
DB_POOL_LIMIT=10

RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672
RABBITMQ_EXCHANGE=mall.events
RABBITMQ_QUEUE=delivery.payment.paid
RABBITMQ_ROUTING_KEY=payment.order.paid
EOT

cat > "$ROOT/api-delivery/src/config.js" <<'EOT'
require("dotenv").config();
function must(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}
module.exports = {
  port: Number(process.env.PORT || 3003),
  db: {
    host: must("DB_HOST"),
    port: Number(process.env.DB_PORT || 3306),
    user: must("DB_USER"),
    password: must("DB_PASS"),
    database: must("DB_NAME"),
    connectionLimit: Number(process.env.DB_POOL_LIMIT || 10),
  },
  rabbit: {
    url: must("RABBITMQ_URL"),
    exchange: must("RABBITMQ_EXCHANGE"),
    queue: must("RABBITMQ_QUEUE"),
    routingKey: must("RABBITMQ_ROUTING_KEY"),
  },
};
EOT

cat > "$ROOT/api-delivery/src/db.js" <<'EOT'
const mysql = require("mysql2/promise");
const { db } = require("./config");

const pool = mysql.createPool({
  host: db.host,
  port: db.port,
  user: db.user,
  password: db.password,
  database: db.database,
  waitForConnections: true,
  connectionLimit: db.connectionLimit,
  namedPlaceholders: true,
});

module.exports = { pool };
EOT

cat > "$ROOT/api-delivery/src/utils/asyncWrap.js" <<'EOT'
module.exports = function asyncWrap(fn) {
  return function wrapped(req, res, next) {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
};
EOT

cat > "$ROOT/api-delivery/src/rabbit.js" <<'EOT'
const amqp = require("amqplib");
const { rabbit } = require("./config");

async function connect() {
  const conn = await amqp.connect(rabbit.url);
  const ch = await conn.createChannel();

  await ch.assertExchange(rabbit.exchange, "topic", { durable: true });
  await ch.assertQueue(rabbit.queue, { durable: true });
  await ch.bindQueue(rabbit.queue, rabbit.exchange, rabbit.routingKey);
  ch.prefetch(10);

  return { conn, ch };
}

module.exports = { connect };
EOT

cat > "$ROOT/api-delivery/src/routes/health.js" <<'EOT'
const router = require("express").Router();
const { pool } = require("../db");
const asyncWrap = require("../utils/asyncWrap");

router.get("/", asyncWrap(async (req, res) => {
  await pool.query("SELECT 1");
  res.json({ ok: true, service: "api-delivery" });
}));

module.exports = router;
EOT

cat > "$ROOT/api-delivery/src/controllers/delivery.controller.js" <<'EOT'
const { pool } = require("../db");

const ALLOWED = new Set(["READY", "SHIPPING", "DELIVERED"]);
const NEXT = { READY: "SHIPPING", SHIPPING: "DELIVERED" };

async function getOrder(req, res) {
  const orderNumber = String(req.params.orderNumber || "").trim();

  const [rows] = await pool.query(
    `SELECT order_number, center_id, ordered_at, order_status, customer_id, customer_address, unit, cost
       FROM orders
      WHERE order_number = ?`,
    [orderNumber]
  );

  if (!rows.length) return res.status(404).json({ ok: false, error: "ORDER_NOT_FOUND" });
  res.json({ ok: true, order: rows[0] });
}

async function updateStatus(req, res) {
  const orderNumber = String(req.params.orderNumber || "").trim();
  const nextStatus = String(req.body.status || "").trim().toUpperCase();

  if (!ALLOWED.has(nextStatus)) {
    return res.status(400).json({ ok: false, error: "INVALID_STATUS" });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [rows] = await conn.query(
      `SELECT order_id, order_status FROM orders WHERE order_number=? FOR UPDATE`,
      [orderNumber]
    );
    if (!rows.length) {
      await conn.rollback();
      return res.status(404).json({ ok: false, error: "ORDER_NOT_FOUND" });
    }

    const cur = (rows[0].order_status || "").toUpperCase();
    if (NEXT[cur] !== nextStatus) {
      await conn.rollback();
      return res.status(409).json({
        ok: false,
        error: "INVALID_TRANSITION",
        message: `current=${cur}, allowed=${NEXT[cur] || "none"}`,
      });
    }

    await conn.query(`UPDATE orders SET order_status=? WHERE order_id=?`, [nextStatus, rows[0].order_id]);
    await conn.commit();
    res.json({ ok: true, orderNumber, status: nextStatus });
  } catch (e) {
    try { await conn.rollback(); } catch {}
    throw e;
  } finally {
    conn.release();
  }
}

module.exports = { getOrder, updateStatus };
EOT

cat > "$ROOT/api-delivery/src/routes/delivery.js" <<'EOT'
const router = require("express").Router();
const asyncWrap = require("../utils/asyncWrap");
const ctrl = require("../controllers/delivery.controller");

router.get("/orders/:orderNumber", asyncWrap(ctrl.getOrder));
router.patch("/orders/:orderNumber/status", asyncWrap(ctrl.updateStatus));

module.exports = router;
EOT

cat > "$ROOT/api-delivery/src/consumer.js" <<'EOT'
const { connect } = require("./rabbit");
const { pool } = require("./db");
const { rabbit } = require("./config");

async function ensureDefaultCenter(conn) {
  await conn.query(
    `INSERT INTO centers (center_id, center_name)
     VALUES (1, 'DEFAULT_CENTER')
     ON DUPLICATE KEY UPDATE center_name=center_name`
  );
}

async function handlePaid(event) {
  const eventId = event.eventId;
  const orderNumber = event.data?.orderNumber;
  const customerId = event.data?.customerId ?? null;

  if (!eventId || !orderNumber) throw new Error("Invalid event payload: missing eventId/orderNumber");

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [inbox] = await conn.query(
      `SELECT event_id FROM inbox_events WHERE event_id=? FOR UPDATE`,
      [eventId]
    );
    if (inbox.length) {
      await conn.rollback();
      return { duplicated: true };
    }

    await conn.query(`INSERT INTO inbox_events (event_id) VALUES (?)`, [eventId]);

    await ensureDefaultCenter(conn);

    await conn.query(
      `INSERT INTO orders (order_number, center_id, ordered_at, order_status, customer_id, customer_address, unit, cost)
       VALUES (?, 1, NOW(), 'READY', ?, NULL, 0, NULL)
       ON DUPLICATE KEY UPDATE order_status = VALUES(order_status)`,
      [orderNumber, customerId]
    );

    await conn.commit();
    return { duplicated: false };
  } catch (e) {
    try { await conn.rollback(); } catch {}
    throw e;
  } finally {
    conn.release();
  }
}

async function main() {
  const { conn, ch } = await connect();
  console.log("[api-delivery] consumer connected. waiting messages...");

  ch.consume(
    rabbit.queue,
    async (msg) => {
      if (!msg) return;
      try {
        const event = JSON.parse(msg.content.toString("utf8"));
        if (event.type !== "payment.order.paid") {
          ch.ack(msg);
          return;
        }
        const result = await handlePaid(event);
        ch.ack(msg);

        if (result.duplicated) console.log("[delivery] duplicated event ignored:", event.eventId);
        else console.log("[delivery] order READY created:", event.data.orderNumber);
      } catch (e) {
        console.error("[delivery] failed:", e.message);
        ch.nack(msg, false, true);
      }
    },
    { noAck: false }
  );

  process.on("SIGINT", async () => {
    try { await ch.close(); } catch {}
    try { await conn.close(); } catch {}
    process.exit(0);
  });
}

main().catch((e) => {
  console.error("consumer boot failed:", e);
  process.exit(1);
});
EOT

cat > "$ROOT/api-delivery/src/app.js" <<'EOT'
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");

const health = require("./routes/health");
const delivery = require("./routes/delivery");

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(morgan("dev"));

app.use("/health", health);
app.use("/delivery", delivery);

app.use((req, res) => res.status(404).json({ ok: false, error: "NOT_FOUND" }));
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ ok: false, error: "INTERNAL_ERROR", message: err.message });
});

module.exports = { app };
EOT

cat > "$ROOT/api-delivery/src/server.js" <<'EOT'
const { app } = require("./app");
const { port } = require("./config");
const { pool } = require("./db");

async function start() {
  await pool.query("SELECT 1");
  app.listen(port, "0.0.0.0", () => console.log(`[api-delivery] listening on :${port}`));
}

start().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
EOT

# -----------------------------------------
# docker-compose.yml (RabbitMQ 포함: 로컬 테스트용)
# -----------------------------------------
cat > "$ROOT/docker-compose.yml" <<'EOT'
services:
  rabbitmq:
    image: rabbitmq:3-management
    container_name: rabbitmq
    ports:
      - "5672:5672"
      - "15672:15672"

  api-product:
    build: ./api-product
    env_file: ./api-product/.env
    ports:
      - "3005:3005"

  api-customer:
    build: ./api-customer
    env_file: ./api-customer/.env
    ports:
      - "3006:3006"

  api-cart:
    build: ./api-cart
    env_file: ./api-cart/.env
    ports:
      - "3007:3007"

  api-order:
    build: ./api-order
    env_file: ./api-order/.env
    ports:
      - "3008:3008"
    depends_on:
      - api-cart

  api-payment:
    build: ./api-payment
    env_file: ./api-payment/.env
    ports:
      - "3001:3001"
    depends_on:
      - rabbitmq

  api-delivery:
    build: ./api-delivery
    env_file: ./api-delivery/.env
    ports:
      - "3003:3003"
    depends_on:
      - rabbitmq

  api-delivery-consumer:
    build: ./api-delivery
    env_file: ./api-delivery/.env
    command: ["node","src/consumer.js"]
    depends_on:
      - rabbitmq
EOT

echo "DONE. created in $ROOT"
