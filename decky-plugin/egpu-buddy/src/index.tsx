import { ButtonItem, ConfirmModal, Field, PanelSection, PanelSectionRow, SliderField, ToggleField, Router, showModal, staticClasses } from "@decky/ui";
import { callable, definePlugin, useQuickAccessVisible } from "@decky/api";
import { useEffect, useState } from "react";
import { FaPlug } from "react-icons/fa";

type Status = {
  present: boolean; bdf: string; vendor?: string; driver_loaded: boolean; game_mode: boolean; game_running: boolean;
  attach_pending: boolean; on_egpu: boolean; output: string;
  gm_status: { state?: string; message?: string }; desktop_status: { state?: string; message?: string };
  link: { speed: string; width: string }; displays: { name: string; enabled: boolean }[]; audio_sink: string;
  telemetry: Record<string, string>; ts: number;
};
type Result = { ok: boolean; message: string; rc?: number };

const getStatus = callable<[], Status>("get_status");
const attach = callable<[boolean], Result>("attach");
const safeDetach = callable<[], Result>("safe_detach");
const setPowerLimit = callable<[number], Result>("set_power_limit");
const setCoreOffset = callable<[number], Result>("set_core_offset");
const resetClocks = callable<[], Result>("reset_clocks");
type Setup = { installed_version: string; payload_version: string; needs_reboot: boolean; helpers_present: boolean; busy: boolean; step: string; rc: number | null; progress: number; can_build_driver: boolean; cmdline_missing: string; unsupported: string; log: string };
const getSetup = callable<[], Setup>("get_setup_status");
const installSystem = callable<[boolean], Result>("install_system");
const uninstallSystem = callable<[], Result>("uninstall_system");
const rebootSystem = callable<[], Result>("reboot_system");
const restartGamemode = callable<[], Result>("restart_gamemode");
const applyCmdline = callable<[], Result>("apply_kernel_cmdline");
type Upd = { auto_update: boolean; held_version?: string; available: string; state: string; checked: number; last_error: string; installed: string };
const getUpdate = callable<[], Upd>("get_update_status");
const setAutoUpdate = callable<[boolean], Result>("set_auto_update");
const checkUpdate = callable<[boolean], Result>("check_update");
type Versions = { ok: boolean; message?: string; current?: string; versions: { version: string; beta: boolean }[] };
const listVersions = callable<[], Versions>("list_versions");
const installVersion = callable<[string], Result>("install_version");

const PLUGIN_VERSION = "0.8.0-beta3";

const Progress = ({ pct, title, step }: { pct: number; title: string; step: string }) => (
  <div style={{ width: "100%", boxSizing: "border-box", padding: "4px 0" }}>
    <div style={{ display: "flex", justifyContent: "space-between", fontSize: "12px", marginBottom: "4px" }}><span>{title}</span><span>{Math.round(pct)}%</span></div>
    <div style={{ width: "100%", height: "6px", borderRadius: "3px", background: "rgba(255,255,255,0.15)", overflow: "hidden" }}>
      <div style={{ width: `${Math.max(0, Math.min(100, pct))}%`, height: "100%", background: "#1a9fff", transition: "width .4s" }} />
    </div>
    <div style={{ fontSize: "11px", opacity: 0.75, marginTop: "4px", whiteSpace: "normal", wordBreak: "break-word" }}>{step.length > 70 ? step.slice(0, 70) + "…" : step}</div>
  </div>
);

const Row = ({ k, v }: { k: string; v: string }) => (
  <PanelSectionRow><Field label={k} focusable={false} bottomSeparator="none"><span style={{ fontSize: "12px", wordBreak: "break-all" }}>{v || "—"}</span></Field></PanelSectionRow>
);

function stateLine(s: Status): string {
  if (!s.present) return s.driver_loaded ? "eGPU off the bus (driver still loaded)" : "No eGPU attached";
  if (s.game_mode) return s.on_egpu ? `Attached — Game Mode on ${s.output}` : "eGPU present — Game Mode on the handheld screen";
  return "eGPU present (Desktop)";
}

function Content() {
  const visible = useQuickAccessVisible();
  const [tab, setTab] = useState<"main" | "details" | "setup">("main");
  const [su, setSu] = useState<Setup | null>(null);
  const [up, setUp] = useState<Upd | null>(null);
  const [vers, setVers] = useState<Versions | null>(null);
  const [confirmSetup, setConfirmSetup] = useState<"" | "install" | "uninstall">("");
  const [s, setS] = useState<Status | null>(null);
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);
  const [pl, setPl] = useState<number | null>(null);
  const [off, setOff] = useState(0);

  const refresh = async () => { try { setS(await getStatus()); setSu(await getSetup()); setUp(await getUpdate()); } catch (e) { setMsg(`status error: ${e}`); } };
  useEffect(() => { if (!visible) return; refresh(); const t = setInterval(refresh, su?.busy ? 1000 : 3000); return () => clearInterval(t); }, [visible, su?.busy]);

  const gameUp = !!(s?.game_running || Router.MainRunningApp);
  const run = async (fn: () => Promise<Result>) => { setBusy(true); try { const r = await fn(); setMsg(r.message); } catch (e) { setMsg(`${e}`); } finally { setBusy(false); refresh(); } };

  const tel = s?.telemetry ?? {};
  const plMin = Number(tel["power.min_limit"] ?? 100), plMax = Number(tel["power.max_limit"] ?? 320);
  const plNow = pl ?? Math.round(Number(tel["power.limit"] ?? plMax));
  const controlsOk = !!(s?.present && s?.driver_loaded && s?.on_egpu);

  return (
    <>
      <PanelSection>
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => setTab(tab === "main" ? "details" : tab === "details" ? "setup" : "main")}>{tab === "main" ? "Show details" : tab === "details" ? "Show setup & updates" : "Back to main"}</ButtonItem>
        </PanelSectionRow>
      </PanelSection>
      {tab === "main" && (
        <PanelSection title="eGPU">
          <PanelSectionRow><div className={staticClasses.Text}>{s ? stateLine(s) : "Loading…"}</div></PanelSectionRow>
          {su?.unsupported && <PanelSectionRow><div style={{ fontSize: "12px", color: "#ff6b6b" }}>{su.unsupported}</div></PanelSectionRow>}
          {su && !su.unsupported && (!su.helpers_present || su.installed_version !== su.payload_version) && !su.busy && su.rc !== 0 && (
            <>
              <PanelSectionRow><div style={{ fontSize: "12px", color: "#f0b429" }}>{su.installed_version && !su.helpers_present ? `The system integration (${su.installed_version}) is missing after an OS update.` : su.installed_version ? `Version ${su.installed_version} is installed; this plugin is ${su.payload_version}.` : "The eGPU system integration is not installed yet."} One press installs everything: hot-plug scripts, Game Mode session, GBM gamescope, boot policy, desktop app, the patched hot-unplug driver with the NVIDIA userspace pinned to it, and the kernel parameters. Backups are kept. Several minutes.</div></PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => run(() => installSystem(false))}>{su.installed_version && !su.helpers_present ? "Repair system integration" : su.installed_version ? "Update system integration" : "Install system integration"}</ButtonItem></PanelSectionRow>
            </>
          )}
          {up?.available && !su?.busy && <PanelSectionRow><div style={{ fontSize: "12px", color: "#f0b429" }}>Update {up.available} is available{up.auto_update ? " and will install automatically when no game is running" : ""}.</div></PanelSectionRow>}
          {up?.available && !su?.busy && <PanelSectionRow><ButtonItem layout="below" disabled={busy || gameUp} onClick={() => run(() => checkUpdate(true))}>Update now to {up.available}</ButtonItem></PanelSectionRow>}
          {up?.state && <PanelSectionRow><div style={{ fontSize: "12px", color: up.state.includes("failed") ? "#ff6b6b" : "#4caf50" }}>{up.state}</div></PanelSectionRow>}
          {su?.busy && <PanelSectionRow><Progress pct={su.progress} title={(su.step.startsWith("update") || up?.state.startsWith("installing")) ? "Updating" : "Installing"} step={su.step} /></PanelSectionRow>}
          {su && !su.busy && su.rc === 0 && (
            <>
              {su.needs_reboot ? (
                <>
                  <PanelSectionRow><div style={{ fontSize: "12px", color: "#4caf50" }}>Installed. The driver or kernel parameters changed, so a full reboot is needed (with the eGPU disconnected on a first install).</div></PanelSectionRow>
                  <PanelSectionRow><ButtonItem layout="below" onClick={() => run(rebootSystem)}>Reboot the system</ButtonItem></PanelSectionRow>
                </>
              ) : (
                <>
                  <PanelSectionRow><div style={{ fontSize: "12px", color: "#4caf50" }}>Installed. No reboot needed: hot-plug scripts are live now; the Game Mode session pieces apply when Game Mode restarts.</div></PanelSectionRow>
                  <PanelSectionRow><ButtonItem layout="below" disabled={busy || gameUp} onClick={() => run(restartGamemode)}>Restart Game Mode now</ButtonItem></PanelSectionRow>
                </>
              )}
            </>
          )}
          {su && !su.busy && su.helpers_present && su.cmdline_missing && (
            <>
              <PanelSectionRow><div style={{ fontSize: "12px", color: "#f0b429" }}>Kernel parameters missing: {su.cmdline_missing}. Without them the eGPU can fail to enumerate or crash the boot. One press writes them to the bootloader (backup kept); reboot before plugging the eGPU in.</div></PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => run(applyCmdline)}>Apply kernel parameters</ButtonItem></PanelSectionRow>
            </>
          )}
          {su && !su.busy && su.rc !== null && su.rc !== 0 && <PanelSectionRow><div style={{ fontSize: "12px", color: "#ff6b6b" }}>Install failed (rc {su.rc}). Log: /tmp/egpu-buddy-setup.log</div></PanelSectionRow>}
          {s && !s.game_mode && <PanelSectionRow><div style={{ fontSize: "12px", opacity: 0.8 }}>In Desktop mode use the EGPU Buddy desktop app.</div></PanelSectionRow>}
          {s?.attach_pending && <PanelSectionRow><div style={{ fontSize: "12px" }}>eGPU plugged in. Close the game, then press Attach.</div></PanelSectionRow>}
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !s?.game_mode || gameUp || (s?.present && s?.on_egpu)} onClick={() => showModal(<ConfirmModal strTitle="Attach the eGPU" strDescription="Game Mode restarts on the eGPU display: the screen goes dark for a few seconds. When it is back, reopen this menu to see the result." strOKButtonText="Attach" onOK={() => run(() => attach(false))} />)}>Attach eGPU</ButtonItem>
          </PanelSectionRow>
          {gameUp && s?.game_mode && <PanelSectionRow><div style={{ fontSize: "12px", color: "#f0b429" }}>A game is running. Close it before attaching or detaching (both restart Game Mode).</div></PanelSectionRow>}
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !s?.game_mode || !s?.present || gameUp} onClick={() => showModal(<ConfirmModal strTitle="Safe Detach" strDescription="Game Mode moves to the handheld screen and the eGPU is removed from the bus: the screen goes dark for a few seconds and the monitor loses signal. Do not unplug yet. When the handheld screen is back, reopen this menu: it says when it is safe to unplug the cable." strOKButtonText="Detach" bDestructiveWarning onOK={() => run(safeDetach)} />)}>Safe Detach</ButtonItem>
          </PanelSectionRow>
          {s?.gm_status?.state && s.gm_status.state !== "ATTACHED" && s.gm_status.state !== "IDLE" && <PanelSectionRow><div style={{ fontSize: "13px", fontWeight: 600, color: s.gm_status.state === "SAFE_COMPLETE" || s.gm_status.state === "DETACHED" ? "#4caf50" : s.gm_status.state.includes("DO_NOT") || s.gm_status.state === "FAILED" ? "#ff6b6b" : "#f0b429" }}>{s.gm_status.state === "SAFE_COMPLETE" || s.gm_status.state === "DETACHED" ? "Safe to unplug the cable." : s.gm_status.message}</div></PanelSectionRow>}
          {msg && <PanelSectionRow><div style={{ fontSize: "12px" }}>{msg}</div></PanelSectionRow>}
          <PanelSectionRow><div style={{ fontSize: "11px", opacity: 0.7 }}>EGPU Buddy {su?.installed_version && su.installed_version !== PLUGIN_VERSION ? `${PLUGIN_VERSION} (system files ${su.installed_version}, update pending)` : PLUGIN_VERSION}{su && !su.installed_version ? " · not installed" : ""} · {up ? (up.available ? `update ${up.available} available` : up.checked ? "up to date" : "update check pending") : "…"}{up?.auto_update ? " · auto-update on" : " · auto-update off"}</div></PanelSectionRow>
        </PanelSection>
      )}
      {tab === "details" && s && (
        <>
          <PanelSection title="eGPU details">
            {!s.present ? (
              <>
                <PanelSectionRow><div className={staticClasses.Text}>eGPU not connected.</div></PanelSectionRow>
                <Row k="Session" v={s.game_mode ? "Game Mode on the handheld screen" : "Desktop"} />
              </>
            ) : (
            <>
              <Row k="GPU" v={tel["name"] ?? (s.present ? s.bdf : "absent")} />
              <Row k="Driver" v={s.driver_loaded ? ((s.vendor ?? "nvidia") === "nvidia" ? `nvidia ${tel["driver_version"] ?? ""}` : `${tel["driver_version"] ?? s.vendor} (experimental support)`) : "not loaded"} />
              <Row k="PCIe" v={s.present ? `${s.link.speed} x${s.link.width}` : ""} />
              <Row k="Session" v={s.game_mode ? (s.on_egpu ? `Game Mode on ${s.output}` : "Game Mode on panel") : "Desktop"} />
              <Row k="Displays" v={s.displays.map((d) => `${d.name}${d.enabled ? "" : " (off)"}`).join(", ")} />
              <Row k="Audio" v={s.audio_sink.replace("alsa_output.", "").replace(".pro-output-0", "").replace(/^pci-0000_/, "")} />
              <Row k="Temp" v={tel["temperature.gpu"] ? `${tel["temperature.gpu"]} °C` : ""} />
              <Row k="Power" v={tel["power.draw"] ? `${tel["power.draw"]} / ${tel["power.limit"]} W` : ""} />
              <Row k="Clocks" v={tel["clocks.gr"] ? `${tel["clocks.gr"]} MHz core, ${tel["clocks.mem"]} MHz mem` : ""} />
              <Row k="VRAM" v={tel["memory.used"] ? `${tel["memory.used"]} / ${tel["memory.total"]} MiB` : ""} />
              <Row k="Load" v={tel["utilization.gpu"] ? `${tel["utilization.gpu"]} %` : ""} />
              <Row k="Fan" v={tel["fan.speed"] && tel["fan.speed"] !== "[N/A]" ? `${tel["fan.speed"]} %` : ""} />
            </>
            )}
          </PanelSection>
          {!s.present ? null : controlsOk ? (
            <PanelSection title="Power controls">
              <PanelSectionRow>
                <SliderField label="Power limit (W)" value={plNow} min={plMin} max={plMax} step={5} showValue onChange={setPl} />
              </PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy || pl === null} onClick={() => run(() => setPowerLimit(plNow))}>Apply power limit</ButtonItem></PanelSectionRow>
              {(s.vendor ?? "nvidia") === "nvidia" && (<>
              <PanelSectionRow>
                <SliderField label="Core clock offset (MHz)" value={off} min={-300} max={300} step={15} showValue onChange={setOff} />
              </PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => run(() => setCoreOffset(off))}>Apply offset</ButtonItem></PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => { setOff(0); setPl(null); run(resetClocks); }}>Reset clocks</ButtonItem></PanelSectionRow>
              </>)}
              {msg && <PanelSectionRow><div style={{ fontSize: "12px" }}>{msg}</div></PanelSectionRow>}
            </PanelSection>
          ) : (
            <PanelSection title="Power controls"><PanelSectionRow><div style={{ fontSize: "12px", opacity: 0.8 }}>Available when Game Mode runs on the eGPU. On the handheld GPU, Game Mode's own performance menu applies.</div></PanelSectionRow></PanelSection>
          )}
        </>
      )}
      {tab === "setup" && (
        <PanelSection title="System integration">
          <PanelSectionRow><div style={{ fontSize: "12px" }}>
            {su ? (su.installed_version ? `Installed: ${su.installed_version}` : "Not installed") : "…"}
          </div></PanelSectionRow>
          <PanelSectionRow><div style={{ fontSize: "12px", opacity: 0.8 }}>Reinstalls everything the first page installs. Everything replaced is backed up. The payload ships inside this plugin; the driver build needs the Arch mirrors.</div></PanelSectionRow>
          {su?.busy && <PanelSectionRow><Progress pct={su.progress} title="Installing" step={su.step} /></PanelSectionRow>}
          {su && !su.busy && su.rc !== null && <PanelSectionRow><div style={{ fontSize: "12px", color: su.rc === 0 ? "#4caf50" : "#ff6b6b" }}>{su.rc === 0 ? "Finished. Reboot to activate." : `Failed (rc ${su.rc}); log: /tmp/egpu-buddy-setup.log`}</div></PanelSectionRow>}
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !!su?.busy} onClick={() => showModal(<ConfirmModal strTitle={su?.installed_version ? "Reinstall the system integration" : "Install the system integration"} strDescription="Runs the full installer as root: hot-plug scripts, Game Mode session, GBM gamescope, boot policy, desktop app, patched driver, kernel parameters. Everything replaced is backed up. Takes several minutes. Do this only if something is broken or after a reinstall of the OS." strOKButtonText={su?.installed_version ? "Reinstall" : "Install"} onOK={() => run(() => installSystem(false))} />)}>
              {confirmSetup === "install" ? "Press again to confirm install" : (su?.installed_version ? "Reinstall / update system integration" : "Install system integration")}
            </ButtonItem>
          </PanelSectionRow>
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !!su?.busy || !su?.installed_version} onClick={() => { if (confirmSetup === "uninstall") { setConfirmSetup(""); run(uninstallSystem); } else setConfirmSetup("uninstall"); }}>
              {confirmSetup === "uninstall" ? "Press again to confirm uninstall" : "Uninstall system integration"}
            </ButtonItem>
          </PanelSectionRow>
          {su?.log && <PanelSectionRow><div style={{ fontSize: "10px", whiteSpace: "pre-wrap", opacity: 0.8 }}>{su.log}</div></PanelSectionRow>}
        </PanelSection>
      )}
      {tab === "setup" && (
        <PanelSection title="Updates">
          <PanelSectionRow><ToggleField label="Automatic updates" description="Off: new releases are only announced here and you decide when to install. On: they install by themselves when no game is running." checked={!!up?.auto_update} onChange={(v) => run(() => setAutoUpdate(v))} /></PanelSectionRow>
          <PanelSectionRow><ButtonItem layout="below" disabled={busy || !!su?.busy} onClick={() => run(() => checkUpdate(false))}>Check for updates now</ButtonItem></PanelSectionRow>
          {up?.available && !su?.busy && <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => run(() => checkUpdate(true))}>Update now to {up.available}</ButtonItem></PanelSectionRow>}
          <PanelSectionRow><div style={{ fontSize: "12px", opacity: 0.8 }}>{up ? (up.available ? `Available: ${up.available}` : (up.checked ? "Up to date." : "Not checked yet.")) + (up.installed ? ` Installed: ${up.installed}.` : "") + (up.last_error ? ` ${up.last_error}` : "") : "…"}</div></PanelSectionRow>
          {up?.held_version && <PanelSectionRow><div style={{ fontSize: "12px", color: "#ffc107" }}>Staying on {up.held_version}: you chose this version, nothing updates it until you press Update or pick another one.</div></PanelSectionRow>}
          <PanelSectionRow><ButtonItem layout="below" disabled={busy || !!su?.busy} onClick={async () => { const r = await listVersions(); setVers(r); if (!r.ok) setMsg(r.message ?? ""); }}>Install another version (go back, or try a beta)</ButtonItem></PanelSectionRow>
          {vers?.versions.map((v) => (
            <PanelSectionRow key={v.version}>
              <ButtonItem layout="below" disabled={busy || !!su?.busy || v.version === vers.current} onClick={() => showModal(<ConfirmModal strTitle={`Install ${v.version}`} strDescription={`Replaces the system integration and this plugin with ${v.version}${v.beta ? " (beta: untested, may break things)" : ""}. Automatic updates are switched off so it stays on this version. Reboot afterwards.`} strOKButtonText="Install" onOK={() => run(() => installVersion(v.version))} />)}>
                {v.version}{v.beta ? " (beta)" : ""}{v.version === vers.current ? " — installed" : ""}
              </ButtonItem>
            </PanelSectionRow>
          ))}
          {msg && <PanelSectionRow><div style={{ fontSize: "12px" }}>{msg}</div></PanelSectionRow>}
        </PanelSection>
      )}
    </>
  );
}

export default definePlugin(() => ({
  name: "EGPU Buddy",
  title: <div className={staticClasses.Title}>EGPU Buddy</div>,
  content: <Content />,
  icon: <FaPlug />,
}));
