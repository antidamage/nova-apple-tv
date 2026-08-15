#!/usr/bin/env node
// Regenerates OrbInfoConformanceCases.swift from the shared case table so the
// tvOS formatter is held to the SAME table as the web dashboard's vitest run.
//
//   node nova-appletv-dashboard/scripts/generate-orb-info-cases.mjs
//
// Run this whenever nova-ha-dashboard/lib/orb-info/format-cases.json changes.
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const source = path.resolve(here, "../../nova-ha-dashboard/lib/orb-info/format-cases.json");
const target = path.resolve(here, "../NovaAppleTVDashboard/OrbInfoConformanceCases.swift");

const json = readFileSync(source, "utf8");
if (json.includes('"""')) {
  throw new Error("Case table contains a Swift raw-string terminator; escape it before embedding.");
}

writeFileSync(target, `// GENERATED FILE — do not edit by hand.
//
// The status orb readout formatter's shared conformance table, embedded so the
// tvOS port is held to exactly the same cases as the web dashboard's
// lib/orb-info/format.test.ts. Regenerate with:
//
//   node nova-appletv-dashboard/scripts/generate-orb-info-cases.mjs
//
// Source of truth: nova-ha-dashboard/lib/orb-info/format-cases.json

enum OrbInfoConformanceCases {
    static let json = #"""
${json.trimEnd()}
"""#
}
`, "utf8");

console.log(`Wrote ${path.relative(process.cwd(), target)}`);
