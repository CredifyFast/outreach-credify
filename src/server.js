// outreach-credify — boot skeleton.
// This file proves the environment end to end (env file, DB, socket, nginx,
// pm2, deploy) via GET /api/health. All other routes are specified in
// CLAUDE.md — extend this file (or mount routers from src/routes/), do not
// rewrite it.
"use strict";

require("dotenv").config({
  path: process.env.ENV_FILE || "/etc/credify/outreach.env",
});

const fs = require("fs");
const path = require("path");
const express = require("express");
const { prisma } = require("./db");

const { DATABASE_URL, SOCKET_PATH, PORT } = process.env;
if (!DATABASE_URL) {
  console.error("FATAL: DATABASE_URL is not set");
  process.exit(1);
}
if (!SOCKET_PATH && !PORT) {
  console.error("FATAL: set SOCKET_PATH (unix socket) or PORT (loopback TCP)");
  process.exit(1);
}

const app = express();
app.use(express.json({ limit: "10mb" })); // job payloads embed rendered recipients

// Static front-end. nginx serves public/ directly in production; this keeps
// parity when hitting the app process straight on the server.
app.use(express.static(path.join(__dirname, "..", "public")));

// --- health: proves DB connectivity through Prisma -------------------------
app.get("/api/health", async (_req, res, next) => {
  try {
    const contacts = await prisma.contact.count();
    res.json({ ok: true, contacts });
  } catch (err) {
    next(err);
  }
});

// TODO(Claude): mount the API here per CLAUDE.md —
//   GET /api/state, GET /api/verify, and every route in the
//   CLUSTER_EMAIL_DB_README.md §3 endpoint→table map.
// Keep the two handlers below LAST so they run after all real routes.

// --- unknown /api route → 404 in the standard error shape ------------------
app.use("/api", (_req, res) =>
  res
    .status(404)
    .json({ error: { code: "not_found", message: "Unknown API route" } })
);

// --- error handler: message only — NEVER log request bodies ----------------
app.use((err, _req, res, _next) => {
  console.error(err.message);
  res
    .status(500)
    .json({ error: { code: "internal", message: "Internal server error" } });
});

// --- listen: unix socket by default, loopback TCP as the rollback hatch ----
if (SOCKET_PATH) {
  try {
    fs.unlinkSync(SOCKET_PATH); // clear a stale socket from a crashed process
  } catch (err) {
    if (err.code !== "ENOENT") throw err;
  }
  app.listen(SOCKET_PATH, () => {
    fs.chmodSync(SOCKET_PATH, 0o660); // let nginx (www-data group) connect
    console.log(`outreach-credify listening on ${SOCKET_PATH}`);
  });
} else {
  app.listen(Number(PORT), "127.0.0.1", () => {
    console.log(`outreach-credify listening on 127.0.0.1:${PORT}`);
  });
}
