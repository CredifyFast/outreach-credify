// outreach-credify — single shared PrismaClient. Import { prisma } from
// here everywhere; never construct a second client.
"use strict";

const { PrismaClient } = require("@prisma/client");

const prisma = new PrismaClient();

module.exports = { prisma };
