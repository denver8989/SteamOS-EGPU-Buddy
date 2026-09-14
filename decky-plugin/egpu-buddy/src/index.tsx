import { ButtonItem, Field, PanelSection, PanelSectionRow, ProgressBarWithInfo, SliderField, ToggleField, Router, staticClasses } from "@decky/ui";
import { callable, definePlugin, useQuickAccessVisible } from "@decky/api";
import { useEffect, useState } from "react";
import { FaPlug } from "react-icons/fa";

type Status = {
  present: boolean; bdf: string; driver_loaded: boolean; game_mode: boolean; game_running: boolean;
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
type Setup = { installed_version: string; payload_version: string; helpers_present: boolean; busy: boolean; step: string; rc: number | null; progress: number; can_build_driver: boolean; log: string };
const getSetup = callable<[], Setup>("get_setup_status");
const installSystem = callable<[boolean], Result>("install_system");
const uninstallSystem = callable<[], Result>("uninstall_system");

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
  const [confirmSetup, setConfirmSetup] = useState<"" | "install" | "uninstall">("");
  const [withDriver, setWithDriver] = useState(false);
  const [s, setS] = useState<Status | null>(null);
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);
  const [pl, setPl] = useState<number | null>(null);
  const [off, setOff] = useState(0);

  const refresh = async () => { try { setS(await getStatus()); setSu(await getSetup()); } catch (e) { setMsg(`status error: ${e}`); } };
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
          <ButtonItem layout="below" onClick={() => setTab(tab === "main" ? "details" : tab === "details" ? "setup" : "main")}>{tab === "main" ? "Show details" : tab === "details" ? "Setup" : "Back to main"}</ButtonItem>
        </PanelSectionRow>
      </PanelSection>
      {tab === "main" && (
        <PanelSection title="eGPU">
          <PanelSectionRow><div className={staticClasses.Text}>{s ? stateLine(s) : "Loading…"}</div></PanelSectionRow>
          {su && !su.helpers_present && <PanelSectionRow><div style={{ fontSize: "12px", color: "#f0b429" }}>System integration is not installed. Open Setup (two presses of the button above) to install it.</div></PanelSectionRow>}
          {s && !s.game_mode && <PanelSectionRow><div style={{ fontSize: "12px", opacity: 0.8 }}>In Desktop mode use the EGPU Buddy desktop app.</div></PanelSectionRow>}
          {s?.attach_pending && <PanelSectionRow><div style={{ fontSize: "12px" }}>eGPU plugged in. Close the game, then press Attach.</div></PanelSectionRow>}
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !s?.game_mode || gameUp || (s?.present && s?.on_egpu)} onClick={() => run(() => attach(false))}>Attach eGPU</ButtonItem>
          </PanelSectionRow>
          {gameUp && s?.game_mode && <PanelSectionRow><div style={{ fontSize: "12px", color: "#f0b429" }}>A game is running. Close it before attaching or detaching (both restart Game Mode).</div></PanelSectionRow>}
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !s?.game_mode || !s?.present || gameUp} onClick={() => run(safeDetach)}>Safe Detach</ButtonItem>
          </PanelSectionRow>
          {(s?.gm_status?.message || msg) && <PanelSectionRow><div style={{ fontSize: "12px" }}>{msg || s?.gm_status?.message}</div></PanelSectionRow>}
        </PanelSection>
      )}
      {tab === "details" && s && (
        <>
          <PanelSection title="eGPU details">
            <>
              <Row k="GPU" v={tel["name"] ?? (s.present ? s.bdf : "absent")} />
              <Row k="Driver" v={s.driver_loaded ? `nvidia ${tel["driver_version"] ?? ""}` : "not loaded"} />
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
          </PanelSection>
          {controlsOk ? (
            <PanelSection title="Power controls">
              <PanelSectionRow>
                <SliderField label="Power limit (W)" value={plNow} min={plMin} max={plMax} step={5} showValue onChange={setPl} />
              </PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy || pl === null} onClick={() => run(() => setPowerLimit(plNow))}>Apply power limit</ButtonItem></PanelSectionRow>
              <PanelSectionRow>
                <SliderField label="Core clock offset (MHz)" value={off} min={-300} max={300} step={15} showValue onChange={setOff} />
              </PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => run(() => setCoreOffset(off))}>Apply offset</ButtonItem></PanelSectionRow>
              <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => { setOff(0); setPl(null); run(resetClocks); }}>Reset clocks</ButtonItem></PanelSectionRow>
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
            {su ? (su.installed_version ? `Installed: ${su.installed_version}` : "Not installed") + ` · this plugin carries ${su.payload_version}` : "…"}
          </div></PanelSectionRow>
          <PanelSectionRow><div style={{ fontSize: "12px", opacity: 0.8 }}>Installs the hot-plug scripts, udev/systemd/modprobe/sudoers rules, the Game Mode session integration, the GBM gamescope (prebuilt), the boot policy and the desktop app. Everything replaced is backed up. The payload ships inside this plugin (no internet needed).</div></PanelSectionRow>
          {su?.busy && <PanelSectionRow><ProgressBarWithInfo nProgress={su.progress} sOperationText={su.step} label="Installing" focusable={false} /></PanelSectionRow>}
          {su?.can_build_driver && !su.busy && <PanelSectionRow><ToggleField label="Also build the patched hot-unplug driver" description="Arch-based only. Compiles nvidia-open DKMS modules; several minutes." checked={withDriver} onChange={setWithDriver} /></PanelSectionRow>}
          {su && !su.busy && su.rc !== null && <PanelSectionRow><div style={{ fontSize: "12px", color: su.rc === 0 ? "#4caf50" : "#ff6b6b" }}>{su.rc === 0 ? "Finished. Reboot to activate." : `Failed (rc ${su.rc}); log: /tmp/egpu-buddy-setup.log`}</div></PanelSectionRow>}
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={busy || !!su?.busy} onClick={() => { if (confirmSetup === "install") { setConfirmSetup(""); run(() => installSystem(withDriver)); } else setConfirmSetup("install"); }}>
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
    </>
  );
}

export default definePlugin(() => ({
  name: "EGPU Buddy",
  title: <div className={staticClasses.Title}>EGPU Buddy</div>,
  content: <Content />,
  icon: <FaPlug />,
}));
