import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const projectRoot = path.resolve(import.meta.dirname, "..");
const dashboardModulePath = path.resolve(
  projectRoot,
  "..",
  "nova-ha-dashboard",
  "lib",
  "orb-modules.ts",
);
const swiftPath = path.join(
  projectRoot,
  "NovaAppleTVDashboard",
  "OrbBuiltins.swift",
);

const dashboardModule = await import(pathToFileURL(dashboardModulePath).href);
const json = JSON.stringify(dashboardModule.BUILTIN_ORB_MODULES, null, 2);
const swift = fs.readFileSync(swiftPath, "utf8");
const marker = 'private let builtinOrbModulesJSON = #"""';
const start = swift.indexOf(marker);
if (start < 0) {
  throw new Error(`Could not find ${marker} in ${swiftPath}`);
}
const payloadStart = start + marker.length;
const end = swift.indexOf('"""#', payloadStart);
if (end < 0) {
  throw new Error(`Could not find closing raw-string delimiter in ${swiftPath}`);
}
const updated = `${swift.slice(0, payloadStart)}\n${json}\n${swift.slice(end)}`;
fs.writeFileSync(swiftPath, updated);
console.log(`Synced ${dashboardModule.BUILTIN_ORB_MODULES.length} orb modules to ${swiftPath}`);
