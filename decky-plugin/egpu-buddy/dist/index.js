const manifest = {"name":"EGPU Buddy"};
const API_VERSION = 2;
const internalAPIConnection = window.__DECKY_SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED_deckyLoaderAPIInit;
if (!internalAPIConnection) {
    throw new Error('[@decky/api]: Failed to connect to the loader as as the loader API was not initialized. This is likely a bug in Decky Loader.');
}
let api;
try {
    api = internalAPIConnection.connect(API_VERSION, manifest.name);
}
catch {
    api = internalAPIConnection.connect(1, manifest.name);
    console.warn(`[@decky/api] Requested API version ${API_VERSION} but the running loader only supports version 1. Some features may not work.`);
}
if (api._version != API_VERSION) {
    console.warn(`[@decky/api] Requested API version ${API_VERSION} but the running loader only supports version ${api._version}. Some features may not work.`);
}
const callable = api.callable;
const useQuickAccessVisible = api.useQuickAccessVisible;
const definePlugin = (fn) => {
    return (...args) => {
        return fn(...args);
    };
};

var DefaultContext = {
  color: undefined,
  size: undefined,
  className: undefined,
  style: undefined,
  attr: undefined
};
var IconContext = SP_REACT.createContext && /*#__PURE__*/SP_REACT.createContext(DefaultContext);

var _excluded = ["attr", "size", "title"];
function _objectWithoutProperties(e, t) { if (null == e) return {}; var o, r, i = _objectWithoutPropertiesLoose(e, t); if (Object.getOwnPropertySymbols) { var n = Object.getOwnPropertySymbols(e); for (r = 0; r < n.length; r++) o = n[r], -1 === t.indexOf(o) && {}.propertyIsEnumerable.call(e, o) && (i[o] = e[o]); } return i; }
function _objectWithoutPropertiesLoose(r, e) { if (null == r) return {}; var t = {}; for (var n in r) if ({}.hasOwnProperty.call(r, n)) { if (-1 !== e.indexOf(n)) continue; t[n] = r[n]; } return t; }
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function ownKeys(e, r) { var t = Object.keys(e); if (Object.getOwnPropertySymbols) { var o = Object.getOwnPropertySymbols(e); r && (o = o.filter(function (r) { return Object.getOwnPropertyDescriptor(e, r).enumerable; })), t.push.apply(t, o); } return t; }
function _objectSpread(e) { for (var r = 1; r < arguments.length; r++) { var t = null != arguments[r] ? arguments[r] : {}; r % 2 ? ownKeys(Object(t), true).forEach(function (r) { _defineProperty(e, r, t[r]); }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(e, Object.getOwnPropertyDescriptors(t)) : ownKeys(Object(t)).forEach(function (r) { Object.defineProperty(e, r, Object.getOwnPropertyDescriptor(t, r)); }); } return e; }
function _defineProperty(e, r, t) { return (r = _toPropertyKey(r)) in e ? Object.defineProperty(e, r, { value: t, enumerable: true, configurable: true, writable: true }) : e[r] = t, e; }
function _toPropertyKey(t) { var i = _toPrimitive(t, "string"); return "symbol" == typeof i ? i : i + ""; }
function _toPrimitive(t, r) { if ("object" != typeof t || !t) return t; var e = t[Symbol.toPrimitive]; if (void 0 !== e) { var i = e.call(t, r); if ("object" != typeof i) return i; throw new TypeError("@@toPrimitive must return a primitive value."); } return ("string" === r ? String : Number)(t); }
function Tree2Element(tree) {
  return tree && tree.map((node, i) => /*#__PURE__*/SP_REACT.createElement(node.tag, _objectSpread({
    key: i
  }, node.attr), Tree2Element(node.child)));
}
function GenIcon(data) {
  return props => /*#__PURE__*/SP_REACT.createElement(IconBase, _extends({
    attr: _objectSpread({}, data.attr)
  }, props), Tree2Element(data.child));
}
function IconBase(props) {
  var elem = conf => {
    var {
        attr,
        size,
        title
      } = props,
      svgProps = _objectWithoutProperties(props, _excluded);
    var computedSize = size || conf.size || "1em";
    var className;
    if (conf.className) className = conf.className;
    if (props.className) className = (className ? className + " " : "") + props.className;
    return /*#__PURE__*/SP_REACT.createElement("svg", _extends({
      stroke: "currentColor",
      fill: "currentColor",
      strokeWidth: "0"
    }, conf.attr, attr, svgProps, {
      className: className,
      style: _objectSpread(_objectSpread({
        color: props.color || conf.color
      }, conf.style), props.style),
      height: computedSize,
      width: computedSize,
      xmlns: "http://www.w3.org/2000/svg"
    }), title && /*#__PURE__*/SP_REACT.createElement("title", null, title), props.children);
  };
  return IconContext !== undefined ? /*#__PURE__*/SP_REACT.createElement(IconContext.Consumer, null, conf => elem(conf)) : elem(DefaultContext);
}

// THIS FILE IS AUTO GENERATED
function FaPlug (props) {
  return GenIcon({"attr":{"viewBox":"0 0 384 512"},"child":[{"tag":"path","attr":{"d":"M320,32a32,32,0,0,0-64,0v96h64Zm48,128H16A16,16,0,0,0,0,176v32a16,16,0,0,0,16,16H32v32A160.07,160.07,0,0,0,160,412.8V512h64V412.8A160.07,160.07,0,0,0,352,256V224h16a16,16,0,0,0,16-16V176A16,16,0,0,0,368,160ZM128,32a32,32,0,0,0-64,0v96h64Z"},"child":[]}]})(props);
}

const getStatus = callable("get_status");
const attach = callable("attach");
const safeDetach = callable("safe_detach");
const setPowerLimit = callable("set_power_limit");
const setCoreOffset = callable("set_core_offset");
const resetClocks = callable("reset_clocks");
const getSetup = callable("get_setup_status");
const acceptUntested = callable("accept_untested");
const installSystem = callable("install_system");
const uninstallSystem = callable("uninstall_system");
const rebootSystem = callable("reboot_system");
const restartGamemode = callable("restart_gamemode");
const applyCmdline = callable("apply_kernel_cmdline");
const getUpdate = callable("get_update_status");
const setAutoUpdate = callable("set_auto_update");
const checkUpdate = callable("check_update");
const PLUGIN_VERSION = "0.7.19";
const Progress = ({ pct, title, step }) => (SP_JSX.jsxs("div", { style: { width: "100%", boxSizing: "border-box", padding: "4px 0" }, children: [SP_JSX.jsxs("div", { style: { display: "flex", justifyContent: "space-between", fontSize: "12px", marginBottom: "4px" }, children: [SP_JSX.jsx("span", { children: title }), SP_JSX.jsxs("span", { children: [Math.round(pct), "%"] })] }), SP_JSX.jsx("div", { style: { width: "100%", height: "6px", borderRadius: "3px", background: "rgba(255,255,255,0.15)", overflow: "hidden" }, children: SP_JSX.jsx("div", { style: { width: `${Math.max(0, Math.min(100, pct))}%`, height: "100%", background: "#1a9fff", transition: "width .4s" } }) }), SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.75, marginTop: "4px", whiteSpace: "normal", wordBreak: "break-word" }, children: step.length > 70 ? step.slice(0, 70) + "…" : step })] }));
const Row = ({ k, v }) => (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.Field, { label: k, focusable: false, bottomSeparator: "none", children: SP_JSX.jsx("span", { style: { fontSize: "12px", wordBreak: "break-all" }, children: v || "—" }) }) }));
function stateLine(s) {
    if (!s.present)
        return s.driver_loaded ? "eGPU off the bus (driver still loaded)" : "No eGPU attached";
    if (s.game_mode)
        return s.on_egpu ? `Attached — Game Mode on ${s.output}` : "eGPU present — Game Mode on the handheld screen";
    return "eGPU present (Desktop)";
}
function Content() {
    const visible = useQuickAccessVisible();
    const [tab, setTab] = SP_REACT.useState("main");
    const [su, setSu] = SP_REACT.useState(null);
    const [up, setUp] = SP_REACT.useState(null);
    const staleChecked = SP_REACT.useRef(false);
    const [confirmSetup, setConfirmSetup] = SP_REACT.useState("");
    const [s, setS] = SP_REACT.useState(null);
    const [msg, setMsg] = SP_REACT.useState("");
    const [busy, setBusy] = SP_REACT.useState(false);
    const [pl, setPl] = SP_REACT.useState(null);
    const [off, setOff] = SP_REACT.useState(0);
    const refresh = async () => {
        try {
            setS(await getStatus());
            setSu(await getSetup());
            const u = await getUpdate();
            setUp(u);
            // the hourly check only counts awake time: after a night of sleep the status is stale, so re-check on open (wall clock)
            if (!staleChecked.current && (!u.checked || Date.now() / 1000 - u.checked > 600)) {
                staleChecked.current = true;
                checkUpdate(false);
            }
        }
        catch (e) {
            setMsg(`status error: ${e}`);
        }
    };
    SP_REACT.useEffect(() => { if (!visible)
        return; refresh(); const t = setInterval(refresh, su?.busy ? 1000 : 3000); return () => clearInterval(t); }, [visible, su?.busy]);
    const gameUp = !!(s?.game_running || DFL.Router.MainRunningApp);
    const run = async (fn) => { setBusy(true); try {
        const r = await fn();
        setMsg(r.message);
    }
    catch (e) {
        setMsg(`${e}`);
    }
    finally {
        setBusy(false);
        refresh();
    } };
    const tel = s?.telemetry ?? {};
    const plMin = Number(tel["power.min_limit"] ?? 100), plMax = Number(tel["power.max_limit"] ?? 320);
    const plNow = pl ?? Math.round(Number(tel["power.limit"] ?? plMax));
    const controlsOk = !!(s?.present && s?.driver_loaded && s?.on_egpu);
    const WHAT = "Installs the hot-plug scripts, the Game Mode session, the GBM gamescope, the boot policy, the desktop app, the patched hot-unplug driver with the NVIDIA userspace pinned to it, and the kernel parameters. Backups are kept.";
    const confirmInstall = (title, go) => {
        const needAccept = !!(su?.untested && !su.accepted_untested);
        const time = su?.slow_build ? " On SteamOS the driver is built on /home and merged as a system extension: 15-20 minutes the first time; the system partition is not touched." : " Several minutes.";
        const disclaimer = needAccept ? `NOT TESTED ON THIS HARDWARE: ${su.untested.split("\n").join("; ")}. This project was verified on one machine only (Legion Go 2, RTX 5060 Ti, CachyOS). Here it may not work, may leave the screen dark, or may need a reboot to recover. You install and test it at your own risk.\n\n` : "";
        DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: needAccept ? `${title} (untested hardware)` : title, strDescription: disclaimer + WHAT + time, strOKButtonText: needAccept ? "I accept the risk" : "Continue", onOK: () => run(async () => { if (needAccept)
                await acceptUntested(); return go(); }) }));
    };
    const installClick = () => confirmInstall(su?.installed_version ? "Update the system files" : "Install", () => installSystem(false));
    return (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSection, { children: SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", onClick: () => setTab(tab === "main" ? "details" : tab === "details" ? "setup" : "main"), children: tab === "main" ? "Show details" : tab === "details" ? "Show setup & updates" : "Back to main" }) }) }), tab === "main" && (SP_JSX.jsxs(DFL.PanelSection, { title: "eGPU", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { className: DFL.staticClasses.Text, children: s ? stateLine(s) : "Loading…" }) }), su?.unsupported && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: "#ff6b6b" }, children: su.unsupported }) }), su && !su.unsupported && (!su.helpers_present || su.installed_version !== su.payload_version) && !su.busy && su.rc !== 0 && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: su.installed_version && !su.helpers_present ? "System files are missing (OS update)." : su.installed_version ? `System files ${su.installed_version}, plugin ${su.payload_version}.` : "Not installed yet." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => installClick(), children: su.installed_version && !su.helpers_present ? "Repair system integration" : su.installed_version ? "Update system integration" : "Install system integration" }) })] })), up?.available && up.available !== PLUGIN_VERSION && !su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["Version ", up.available, " is available."] }) }), up?.available && up.available !== PLUGIN_VERSION && !su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => confirmInstall(`Update to ${up.available}`, () => checkUpdate(true)), children: ["Update to ", up.available] }) }), up?.state && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: up.state.includes("failed") ? "#ff6b6b" : undefined, opacity: up.state.includes("failed") ? 1 : 0.8 }, children: up.state }) }), su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(Progress, { pct: su.progress, title: (su.step.startsWith("update") || up?.state.startsWith("installing")) ? "Updating" : "Installing", step: su.step }) }), su && !su.busy && su.rc === 0 && (SP_JSX.jsx(SP_JSX.Fragment, { children: su.needs_reboot ? (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Installed. Reboot with the eGPU unplugged." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", onClick: () => run(rebootSystem), children: "Reboot the system" }) })] })) : (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Installed. Restart Game Mode to finish." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => run(restartGamemode), children: "Restart Game Mode now" }) })] })) })), su && !su.busy && su.helpers_present && su.cmdline_missing && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Kernel parameters not active." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: "Kernel parameters", strDescription: `Missing: ${su.cmdline_missing}. Without them the eGPU can fail to enumerate or crash the boot. They are written to the bootloader configuration (backup kept). Reboot afterwards, before plugging the eGPU in.`, strOKButtonText: "Apply", onOK: () => run(applyCmdline) })), children: "Apply kernel parameters" }) })] })), su && !su.busy && su.rc !== null && su.rc !== 0 && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", color: "#ff6b6b" }, children: ["Install failed (rc ", su.rc, "). Log: /tmp/egpu-buddy-setup.log"] }) }), s && !s.game_mode && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "In Desktop mode use the EGPU Buddy desktop app." }) }), s?.attach_pending && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: "eGPU plugged in. Close the game, then press Attach." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !s?.game_mode || gameUp || (s?.present && s?.on_egpu), onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: "Attach the eGPU", strDescription: "Game Mode restarts on the eGPU display: the screen goes dark for a few seconds. When it is back, reopen this menu to see the result.", strOKButtonText: "Attach", onOK: () => run(() => attach(false)) })), children: "Attach eGPU" }) }), gameUp && s?.game_mode && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "A game is running. Close it before attaching or detaching (both restart Game Mode)." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !s?.game_mode || !s?.present || gameUp, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: "Safe Detach", strDescription: "Game Mode moves to the handheld screen and the eGPU is removed from the bus: the screen goes dark for a few seconds and the monitor loses signal. Do not unplug yet. When the handheld screen is back, reopen this menu: it says when it is safe to unplug the cable.", strOKButtonText: "Detach", bDestructiveWarning: true, onOK: () => run(safeDetach) })), children: "Safe Detach" }) }), s?.gm_status?.state && s.gm_status.state !== "ATTACHED" && s.gm_status.state !== "IDLE" && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "13px", fontWeight: 600, color: s.gm_status.state === "SAFE_COMPLETE" || s.gm_status.state === "DETACHED" ? "#4caf50" : s.gm_status.state.includes("DO_NOT") || s.gm_status.state === "FAILED" ? "#ff6b6b" : "#f0b429" }, children: s.gm_status.state === "SAFE_COMPLETE" || s.gm_status.state === "DETACHED" ? "Safe to unplug the cable." : s.gm_status.message }) }), msg && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: msg }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => run(() => checkUpdate(false)), children: "Check for updates" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "11px", opacity: 0.7 }, children: ["EGPU Buddy ", su?.installed_version && su.installed_version !== PLUGIN_VERSION ? `${PLUGIN_VERSION} (system files ${su.installed_version}, update pending)` : PLUGIN_VERSION, su && !su.installed_version ? " · not installed" : "", " \u00B7 ", up ? (up.available ? `update ${up.available} available` : up.checked ? "up to date" : "update check pending") : "…", up?.auto_update ? " · auto-update on" : " · auto-update off"] }) })] })), tab === "details" && s && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSection, { title: "eGPU details", children: !s.present ? (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { className: DFL.staticClasses.Text, children: "eGPU not connected." }) }), SP_JSX.jsx(Row, { k: "Session", v: s.game_mode ? "Game Mode on the handheld screen" : "Desktop" })] })) : (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(Row, { k: "GPU", v: tel["name"] ?? (s.present ? s.bdf : "absent") }), SP_JSX.jsx(Row, { k: "Driver", v: s.driver_loaded ? `nvidia ${tel["driver_version"] ?? ""}` : "not loaded" }), SP_JSX.jsx(Row, { k: "PCIe", v: s.present ? `${s.link.speed} x${s.link.width}` : "" }), SP_JSX.jsx(Row, { k: "Session", v: s.game_mode ? (s.on_egpu ? `Game Mode on ${s.output}` : "Game Mode on panel") : "Desktop" }), SP_JSX.jsx(Row, { k: "Displays", v: s.displays.map((d) => `${d.name}${d.enabled ? "" : " (off)"}`).join(", ") }), SP_JSX.jsx(Row, { k: "Audio", v: s.audio_sink.replace("alsa_output.", "").replace(".pro-output-0", "").replace(/^pci-0000_/, "") }), SP_JSX.jsx(Row, { k: "Temp", v: tel["temperature.gpu"] ? `${tel["temperature.gpu"]} °C` : "" }), SP_JSX.jsx(Row, { k: "Power", v: tel["power.draw"] ? `${tel["power.draw"]} / ${tel["power.limit"]} W` : "" }), SP_JSX.jsx(Row, { k: "Clocks", v: tel["clocks.gr"] ? `${tel["clocks.gr"]} MHz core, ${tel["clocks.mem"]} MHz mem` : "" }), SP_JSX.jsx(Row, { k: "VRAM", v: tel["memory.used"] ? `${tel["memory.used"]} / ${tel["memory.total"]} MiB` : "" }), SP_JSX.jsx(Row, { k: "Load", v: tel["utilization.gpu"] ? `${tel["utilization.gpu"]} %` : "" }), SP_JSX.jsx(Row, { k: "Fan", v: tel["fan.speed"] && tel["fan.speed"] !== "[N/A]" ? `${tel["fan.speed"]} %` : "" })] })) }), !s.present ? null : controlsOk ? (SP_JSX.jsxs(DFL.PanelSection, { title: "Power controls", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.SliderField, { label: "Power limit (W)", value: plNow, min: plMin, max: plMax, step: 5, showValue: true, onChange: setPl }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || pl === null, onClick: () => run(() => setPowerLimit(plNow)), children: "Apply power limit" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.SliderField, { label: "Core clock offset (MHz)", value: off, min: -300, max: 300, step: 15, showValue: true, onChange: setOff }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => run(() => setCoreOffset(off)), children: "Apply offset" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => { setOff(0); setPl(null); run(resetClocks); }, children: "Reset clocks" }) }), msg && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: msg }) })] })) : (SP_JSX.jsx(DFL.PanelSection, { title: "Power controls", children: SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Available when Game Mode runs on the eGPU. On the handheld GPU, Game Mode's own performance menu applies." }) }) }))] })), tab === "setup" && (SP_JSX.jsxs(DFL.PanelSection, { title: "System integration", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: su ? (su.installed_version ? `Installed: ${su.installed_version}` : "Not installed") : "…" }) }), su?.untested && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["Hardware: ", su.untested.split("\n").join("; "), ". ", su.accepted_untested ? "Risk notice accepted." : "Risk notice not accepted yet."] }) }), su?.cmdline_missing && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["Kernel parameters not active: ", su.cmdline_missing] }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Reinstalls everything the first page installs. Everything replaced is backed up. The payload ships inside this plugin; the driver build needs the Arch mirrors." }) }), su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(Progress, { pct: su.progress, title: "Installing", step: su.step }) }), su && !su.busy && su.rc !== null && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: su.rc === 0 ? "#4caf50" : "#ff6b6b" }, children: su.rc === 0 ? "Finished. Reboot to activate." : `Failed (rc ${su.rc}); log: /tmp/egpu-buddy-setup.log` }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: su?.installed_version ? "Reinstall the system integration" : "Install the system integration", strDescription: "Runs the full installer as root: hot-plug scripts, Game Mode session, GBM gamescope, boot policy, desktop app, patched driver, kernel parameters. Everything replaced is backed up. Takes several minutes. Do this only if something is broken or after a reinstall of the OS.", strOKButtonText: su?.installed_version ? "Reinstall" : "Install", onOK: () => run(() => installSystem(false)) })), children: confirmSetup === "install" ? "Press again to confirm install" : (su?.installed_version ? "Reinstall / update system integration" : "Install system integration") }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy || !su?.installed_version, onClick: () => { if (confirmSetup === "uninstall") {
                                setConfirmSetup("");
                                run(uninstallSystem);
                            }
                            else
                                setConfirmSetup("uninstall"); }, children: confirmSetup === "uninstall" ? "Press again to confirm uninstall" : "Uninstall system integration" }) }), su?.log && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "10px", whiteSpace: "pre-wrap", opacity: 0.8 }, children: su.log }) })] })), tab === "setup" && (SP_JSX.jsxs(DFL.PanelSection, { title: "Updates", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ToggleField, { label: "Automatic updates", description: "Off (default): a new release is only announced here and you decide when to install it. On: it installs by itself when no game is running.", checked: !!up?.auto_update, onChange: (v) => run(() => setAutoUpdate(v)) }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => run(() => checkUpdate(false)), children: "Check for updates now" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: up ? (up.available ? `Available: ${up.available}` : (up.checked ? "Up to date." : "Not checked yet.")) + (up.installed ? ` Installed: ${up.installed}.` : "") + (up.last_error ? ` ${up.last_error}` : "") : "…" }) })] }))] }));
}
var index = definePlugin(() => ({
    name: "EGPU Buddy",
    title: SP_JSX.jsx("div", { className: DFL.staticClasses.Title, children: "EGPU Buddy" }),
    content: SP_JSX.jsx(Content, {}),
    icon: SP_JSX.jsx(FaPlug, {}),
}));

export { index as default };
//# sourceMappingURL=index.js.map
