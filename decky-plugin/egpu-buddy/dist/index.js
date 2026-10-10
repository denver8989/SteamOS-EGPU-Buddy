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
const toaster = api.toaster;
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
const getUpdate = callable("get_update_status");
const setAutoUpdate = callable("set_auto_update");
const checkUpdate = callable("check_update");
const updateDetached = callable("update_detached");
const popNotice = callable("pop_notice");
const getTrial = callable("get_driver_trial");
const startTrial = callable("start_driver_trial");
const revertTrial = callable("revert_driver_trial");
const ackTrial = callable("ack_driver_trial");
const getScreens = callable("get_screens");
const wakeScreens = callable("wake_screens");
const getScreenOffer = callable("get_screen_offer");
const setGameScreen = callable("set_game_screen");
const getTvControl = callable("get_tv_control");
const setTvControl = callable("set_tv_control");
const pairTv = callable("pair_tv");
// a screen plugged into the eGPU while Game Mode runs on another one: offer to move (one screen at a time)
const maybeOfferScreen = async () => {
    const o = await getScreenOffer();
    if (!o.connector)
        return;
    DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: `${o.name} connected`, strDescription: o.game ? `Close the running game first, then use "Show Game Mode on ${o.name}" in EGPU Buddy.`
            : `${o.detail}\n\nShow Game Mode on ${o.name}? Game Mode restarts on it (the screen goes dark for a few seconds). You can switch back from EGPU Buddy.`, strOKButtonText: o.game ? "OK" : "Switch", strCancelButtonText: "Stay here", onOK: async () => { if (o.game)
            return; const r = await setGameScreen(o.connector); toaster.toast({ title: "EGPU Buddy", body: r.message }); } }));
};
const screenState = { "in-use": "on", "other-input": "other input", standby: "asleep", off: "off" };
const vt = (v) => (v.match(/\d+/g) ?? ["0"]).slice(0, 3).reduce((a, x) => a * 1000 + Number(x), 0);
const PLUGIN_VERSION = "0.7.83";
const mmss = (sec) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, "0")}`;
// The percentage follows real stages (and real compile output); the running clock shows it is alive between stage changes.
const Progress = ({ pct, title, step, started, expect }) => (SP_JSX.jsxs("div", { style: { width: "100%", boxSizing: "border-box", padding: "4px 0" }, children: [SP_JSX.jsxs("div", { style: { display: "flex", justifyContent: "space-between", fontSize: "12px", marginBottom: "4px" }, children: [SP_JSX.jsx("span", { children: title }), SP_JSX.jsxs("span", { children: [Math.round(pct), "%"] })] }), SP_JSX.jsx("div", { style: { width: "100%", height: "6px", borderRadius: "3px", background: "rgba(255,255,255,0.15)", overflow: "hidden" }, children: SP_JSX.jsx("div", { style: { width: `${Math.max(0, Math.min(100, pct))}%`, height: "100%", background: "#1a9fff", transition: "width .4s" } }) }), SP_JSX.jsx("div", { style: { fontSize: "12px", marginTop: "4px", whiteSpace: "normal" }, children: step }), SP_JSX.jsxs("div", { style: { fontSize: "11px", opacity: 0.75, marginTop: "2px", whiteSpace: "normal" }, children: [started ? `${mmss(Date.now() / 1000 - started)} elapsed` : "", expect ? ` · usually ${expect}` : ""] }), SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.75, marginTop: "2px", whiteSpace: "normal" }, children: "You can close this menu: it continues, and a notification appears when it is done." })] }));
// one line per row: values are kept short below, and anything still too long for a narrow screen ends in "…" instead of
// breaking mid-word onto a second line ("RTX 5 / 060 Ti", seen on a 5120x1440 monitor and on the handheld panel)
const Row = ({ k, v }) => (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.Field, { label: k, focusable: false, bottomSeparator: "none", children: SP_JSX.jsx("span", { style: { fontSize: "12px", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", display: "block", maxWidth: "100%" }, children: v || "—" }) }) }));
// the screen's own name ("X49 V") instead of its connector ("DP-7") where the EDID gives one
const screenName = (s) => s.displays.find((d) => d.name === s.output)?.model || s.output;
const gpuName = (n) => (n ?? "").replace(/^NVIDIA\s+(GeForce\s+)?/i, "");
// "alsa_output.pci-0000_03_00.1.HiFi__HDMI1__sink" -> "eGPU HDMI 1"; the built-in card -> "Built-in"
const audioName = (sink, bdf) => {
    if (!sink)
        return "";
    const port = sink.match(/(HDMI|DP)(\d*)/i);
    const busDev = bdf.replace(/^0000:/, "").replace(/\.\d$/, "").replace(":", "_");
    if (busDev && sink.includes(busDev))
        return `eGPU${port ? ` ${port[1].toUpperCase()}${port[2] ? " " + port[2] : ""}` : ""}`;
    if (/bluez/i.test(sink))
        return "Bluetooth";
    if (/usb/i.test(sink))
        return "USB audio";
    if (/pro-output|analog|speaker/i.test(sink))
        return "Built-in";
    return sink.replace(/^alsa_output\.(pci-0000_)?/, "").replace(/\.(pro-output-0|.*__sink)$/, "");
};
function stateLine(s) {
    if (!s.present)
        return s.driver_loaded ? "eGPU off the bus (driver still loaded)" : "No eGPU attached";
    if (s.game_mode)
        return s.on_egpu ? `Attached — Game Mode on ${screenName(s)}` : "eGPU present — Game Mode on the handheld screen";
    return "eGPU present (Desktop)";
}
// Beta driver trial: a progress screen that opens by itself whenever Game Mode starts while a trial runs (it restarts
// twice: onto the handheld at the Safe Detach, onto the monitor at the attach), and once more with the result.
let trialOpen = false;
function TrialModal({ closeModal }) {
    const [t, setT] = SP_REACT.useState(null);
    SP_REACT.useEffect(() => {
        let alive = true;
        const tick = async () => { try {
            const x = await getTrial();
            if (alive)
                setT(x);
        }
        catch { /* backend restarting */ } };
        tick();
        const i = setInterval(tick, 1000);
        return () => { alive = false; clearInterval(i); };
    }, []);
    const done = !!t && !t.running;
    const back = !!t && (t.state === "reverting" || t.state === "reverted");
    const close = () => { trialOpen = false; if (done)
        ackTrial(); closeModal?.(); };
    return (SP_JSX.jsx(DFL.ConfirmModal, { strTitle: !t ? "Beta driver" : done ? (t.state === "kept" ? `Beta driver ${t.beta} installed` : t.state === "reverted" ? `Back on the tested driver ${t.tested}` : "Beta driver trial failed") : back ? `Returning to the tested driver ${t.tested}` : `Installing beta driver ${t.beta}`, strDescription: !t ? "…" : done
            ? SP_JSX.jsx("div", { style: { fontSize: "14px", color: t.state === "kept" ? "#4caf50" : t.state === "failed" ? "#ff6b6b" : "#f0b429" }, children: t.message })
            : SP_JSX.jsx(Progress, { pct: t.progress, title: back ? "Reverting" : "Installing", step: t.step, started: t.started, expect: back ? "3-5 minutes" : "5-20 minutes" }), bAlertDialog: true, strOKButtonText: done ? "OK" : "Working… (B hides this)", bOKDisabled: !done, onOK: close, onCancel: close, closeModal: close }));
}
const maybeShowTrial = async () => {
    if (trialOpen)
        return;
    const t = await getTrial();
    const recent = t.started && Date.now() / 1000 - t.started < 7200;
    if (recent && (t.running || (["kept", "reverted", "failed"].includes(t.state) && !t.acked))) {
        trialOpen = true;
        DFL.showModal(SP_JSX.jsx(TrialModal, {}));
    }
};
function Content() {
    const visible = useQuickAccessVisible();
    const [tab, setTab] = SP_REACT.useState("main");
    const [su, setSu] = SP_REACT.useState(null);
    const [up, setUp] = SP_REACT.useState(null);
    const [tv, setTv] = SP_REACT.useState(null);
    const [tr, setTr] = SP_REACT.useState(null);
    const staleChecked = SP_REACT.useRef(false);
    const [confirmSetup, setConfirmSetup] = SP_REACT.useState("");
    const [s, setS] = SP_REACT.useState(null);
    const [scr, setScr] = SP_REACT.useState(null);
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
            setTv(await getTvControl());
            setTr(await getTrial());
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
    // DDC/CI reads are slow-ish and some screens dislike polling: read once when details open
    SP_REACT.useEffect(() => { if (visible && tab === "details")
        getScreens().then(setScr).catch(() => setScr(null)); }, [visible, tab]);
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
    // "mounted" for uninstall purposes: the driver is loaded, so /usr cannot be written and the
    // extension cannot be unmerged. Detaching is what clears it.
    const egpuMounted = !!(s?.driver_loaded);
    const WHAT = "Installs the hot-plug scripts, the Game Mode session, the GBM gamescope, the boot policy, the desktop app, the patched hot-unplug driver with the NVIDIA userspace pinned to it, and the kernel parameters. Backups are kept.";
    const confirmInstall = (title, go, detachGo) => {
        const needAccept = !!(su?.untested && !su.accepted_untested);
        if (detachGo && up?.needs_detach && !needAccept) { // SteamOS with the eGPU in use: the update cannot be written until it is detached
            DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: `${title}: the eGPU is in use`, strOKButtonText: "Detach and update", bDestructiveWarning: true, strDescription: "The eGPU is detached first: Game Mode moves to the handheld screen and the monitor loses signal. Leave the cable plugged in. Then the update installs" + (su?.slow_build ? " (a driver rebuild can take 10-20 minutes; keep the charger connected)" : "") + ". When it is done the eGPU is attached again by itself and Game Mode returns to its screen. A notification tells you each step.", onOK: () => run(detachGo) }));
            return;
        }
        const time = ` Expected time: ${su?.expect ?? "several minutes"}.` + (su?.slow_build ? " The driver is built on /home; the system partition is not touched. Keep the charger connected and the eGPU unplugged." : "") + " You can close the menu meanwhile; a notification appears when it is done.";
        const disclaimer = needAccept ? `NOT TESTED ON THIS HARDWARE: ${su.untested.split("\n").join("; ")}. This project was verified on one machine only (Legion Go 2, RTX 5060 Ti, CachyOS). Here it may not work, may leave the screen dark, or may need a reboot to recover. You install and test it at your own risk.\n\n` : "";
        DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: needAccept ? `${title} (untested hardware)` : title, strDescription: disclaimer + WHAT + time, strOKButtonText: needAccept ? "I accept the risk" : "Continue", onOK: () => run(async () => { if (needAccept)
                await acceptUntested(); return go(); }) }));
    };
    // setup state comes from the SYSTEM, not from the last run: it is the same after closing the menu, a Decky restart or a reboot
    const driverMissing = !!(su?.slow_build && su.installed_version && su.helpers_present && su.driver_ready === false);
    const behind = !!(su?.installed_version && vt(su.installed_version) < vt(su.payload_version));
    const needsInstall = !!(su && !su.unsupported && (!su.helpers_present || !su.installed_version || behind || (!!su.cmdline_missing && !su.cmdline_pending) || driverMissing));
    const updateReady = !!(up?.available && vt(up.available) > vt(PLUGIN_VERSION) && !needsInstall); // an update is offered only when one was detected AND the setup is complete
    const installClick = () => confirmInstall(su?.installed_version ? "Update the system files" : "Install", () => installSystem(false), su?.installed_version ? () => updateDetached("") : undefined);
    // An AMD or Intel eGPU needs neither the patched nvidia-open build (the long part of an install)
    // nor the GBM-scanout gamescope (that exists only to fix the NVIDIA scan-out corruption).
    // Everything else - hot-plug attach, safe detach, cable-pull recovery, the session fallback,
    // audio follow - is vendor-neutral and is still installed.
    return (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsxs(DFL.PanelSection, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", onClick: () => setTab(tab === "main" ? "details" : tab === "details" ? "setup" : "main"), children: tab === "main" ? "Show details" : tab === "details" ? "Show setup & updates" : "Back to main" }) }), tab !== "setup" && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", onClick: () => setTab("setup"), children: "Setup & updates" }) }))] }), tab === "main" && (SP_JSX.jsxs(DFL.PanelSection, { title: "eGPU", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { className: DFL.staticClasses.Text, children: s ? stateLine(s) : "Loading…" }) }), su?.unsupported && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: "#ff6b6b" }, children: su.unsupported }) }), needsInstall && su && !su.busy && su.rc !== 0 && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: su.installed_version && !su.helpers_present ? "System files are missing (OS update)." : behind ? "Update ready — one Game Mode restart finishes it." : driverMissing ? "The NVIDIA driver is not installed. Keep the eGPU unplugged." : su.installed_version ? "Setup is incomplete." : "Not installed yet." }) }), behind && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => run(restartGamemode), children: "Restart Game Mode to finish" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => installClick(), children: behind && su.helpers_present ? "Update system integration" : su.installed_version ? "Repair system integration" : "Install system integration" }) })] })), updateReady && !su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["Version ", up.available, " is available."] }) }), updateReady && !su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => confirmInstall(`Update to ${up.available}`, () => checkUpdate(true), () => updateDetached(up.available)), children: ["Update to ", up.available] }) }), up?.state && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: up.state.includes("failed") ? "#ff6b6b" : undefined, opacity: up.state.includes("failed") ? 1 : 0.8 }, children: up.state }) }), su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(Progress, { pct: su.progress, title: (su.step.startsWith("update") || up?.state.startsWith("installing")) ? "Updating" : "Installing", step: su.step, started: su.started, expect: su.expect }) }), su && !su.busy && su.rc === 0 && (SP_JSX.jsx(SP_JSX.Fragment, { children: su.needs_reboot ? (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: su.egpu_on_bus
                                            ? "Installed. One reboot activates the kernel parameters \u2014 the eGPU can stay plugged in."
                                            : "Installed. One reboot activates the kernel parameters. DO NOT CONNECT THE eGPU UNTIL AFTER THAT REBOOT \u2014 the protections that stop a cable event resetting the machine are kernel parameters, and they are not active yet." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", onClick: () => run(rebootSystem), children: "Reboot the system" }) })] })) : (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Installed. Restart Game Mode to finish." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => run(restartGamemode), children: "Restart Game Mode now" }) })] })) })), su && !su.busy && su.cmdline_pending && su.rc !== 0 && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Reboot to activate the kernel parameters (eGPU unplugged)." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => run(rebootSystem), children: "Reboot the system" }) })] })), su && !su.busy && su.rc !== null && su.rc !== 0 && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: "#ff6b6b" }, children: su.rc === 21 ? "Nothing was changed: the eGPU driver is in use. Safe Detach, unplug the eGPU, then try again." : su.rc === 20 ? "Everything is installed except the NVIDIA driver, which could not be built. Keep the eGPU unplugged, check the internet connection and press Repair. Details: Show setup & updates." : `Install failed (rc ${su.rc}). Log: /tmp/egpu-buddy-setup.log` }) }), !!s?.resets?.count && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["This device was reset by its hardware ", s.resets.count === 1 ? "once" : `${s.resets.count} times`, " while the eGPU was connected (last: ", s.resets.last, "). Always use Safe Detach before unplugging."] }) }), s && !s.game_mode && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "In Desktop mode use the EGPU Buddy desktop app." }) }), s?.attach_pending && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: "eGPU plugged in. Close the game, then press Attach." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !s?.game_mode || gameUp || (s?.present && s?.on_egpu), onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: "Attach the eGPU", strDescription: "Game Mode restarts on the eGPU display: the screen goes dark for a few seconds. When it is back, reopen this menu to see the result.", strOKButtonText: "Attach", onOK: () => run(() => attach(false)) })), children: "Attach eGPU" }) }), s?.game_mode && s.on_egpu && s.displays.filter((d) => d.name !== s.output).map((d) => (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs(DFL.ButtonItem, { layout: "below", disabled: busy || gameUp, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: `Show Game Mode on ${d.model || d.name}`, strDescription: `${d.detail}\n\nGame Mode restarts on that screen: this one goes dark. Switch back the same way.`, strOKButtonText: "Switch", onOK: () => run(() => setGameScreen(d.name)) })), children: ["Show Game Mode on ", d.model || d.name, SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.7 }, children: d.detail })] }) }, d.name))), gameUp && s?.game_mode && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "A game is running. Close it before attaching or detaching (both restart Game Mode)." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !s?.game_mode || !s?.present || gameUp, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: "Safe Detach", strDescription: "Game Mode moves to the handheld screen and the eGPU is removed from the bus: the screen goes dark for a few seconds and the monitor loses signal. Do not unplug yet. When the handheld screen is back, reopen this menu: it says when it is safe to unplug the cable.", strOKButtonText: "Detach", bDestructiveWarning: true, onOK: () => run(safeDetach) })), children: "Safe Detach" }) }), s?.gm_status?.state && s.gm_status.state !== "ATTACHED" && s.gm_status.state !== "IDLE" && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "13px", fontWeight: 600, color: s.gm_status.state === "SAFE_COMPLETE" || s.gm_status.state === "DETACHED" ? "#4caf50" : s.gm_status.state.includes("DO_NOT") || s.gm_status.state === "FAILED" ? "#ff6b6b" : "#f0b429" }, children: s.gm_status.state === "SAFE_COMPLETE" || s.gm_status.state === "DETACHED" ? "Safe to unplug the cable." : s.gm_status.message }) }), tr?.message && (tr.running || tr.state === "reverted" || tr.state === "failed") && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", color: tr.state === "failed" ? "#ff6b6b" : "#f0b429" }, children: ["Beta driver: ", tr.message] }) }), msg && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: msg }) }), su?.step && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.85 }, children: su.step }) }), su?.busy === false && su?.rc === 0 && !su?.installed_version &&
                        SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: "#4caf50" }, children: "Uninstalled. The machine is back to how it was." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => run(() => checkUpdate(false)), children: "Check for updates" }) }), su?.installed_version && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy || egpuMounted, onClick: () => { if (confirmSetup === "uninstall") {
                                        setConfirmSetup("");
                                        run(uninstallSystem);
                                    }
                                    else
                                        setConfirmSetup("uninstall"); }, children: confirmSetup === "uninstall" ? "Press again to confirm uninstall" : "Uninstall" }) }), egpuMounted && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.7 }, children: "Safe Detach the eGPU first: the system files cannot be removed while its driver is running." }) })] })), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "11px", opacity: 0.7 }, children: ["EGPU Buddy ", PLUGIN_VERSION, su && !su.installed_version ? " · not installed" : "", " \u00B7 ", up ? (up.available ? `update ${up.available} available` : up.checked ? "up to date" : "update check pending") : "…", up?.auto_update ? " · auto-update on" : " · auto-update off"] }) })] })), tab === "details" && !s && (SP_JSX.jsx(DFL.PanelSection, { title: "eGPU details", children: SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "No eGPU connected. Setup, updates and uninstall are still available above." }) }) })), tab === "details" && s && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSection, { title: "eGPU details", children: !s.present ? (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { className: DFL.staticClasses.Text, children: "eGPU not connected." }) }), SP_JSX.jsx(Row, { k: "Session", v: s.game_mode ? "Game Mode on handheld" : "Desktop" })] })) : (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(Row, { k: "GPU", v: gpuName(tel["name"]) || (s.present ? s.bdf : "absent") }), SP_JSX.jsx(Row, { k: "Driver", v: s.driver_loaded ? `nvidia ${tel["driver_version"] ?? ""}` : "not loaded" }), SP_JSX.jsx(Row, { k: "PCIe", v: s.present ? `${s.link.speed} x${s.link.width}` : "" }), SP_JSX.jsx(Row, { k: "Session", v: s.game_mode ? (s.on_egpu ? `Game Mode on ${screenName(s)}` : "Game Mode on panel") : "Desktop" }), (scr?.length ? scr : s.displays.map((d) => ({ connector: d.name, name: d.model, state: d.enabled ? "" : "off" }))).map((x) => (SP_JSX.jsx(Row, { k: x.name || x.connector, v: [screenState[x.state], x.connector.startsWith("HDMI") ? "HDMI" : x.connector.startsWith("DP") ? "DisplayPort" : x.connector].filter(Boolean).join(" · ") }, x.connector))), scr?.some((x) => x.ddc) && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => run(async () => { const r = await wakeScreens(); getScreens().then(setScr).catch(() => { }); return r; }), children: "Wake screens" }) }), SP_JSX.jsx(Row, { k: "Audio", v: audioName(s.audio_sink, s.bdf) }), SP_JSX.jsx(Row, { k: "Temp", v: tel["temperature.gpu"] ? `${tel["temperature.gpu"]} °C` : "" }), SP_JSX.jsx(Row, { k: "Power", v: tel["power.draw"] ? `${Math.round(Number(tel["power.draw"]))} / ${Math.round(Number(tel["power.limit"]))} W` : "" }), SP_JSX.jsx(Row, { k: "Core / mem", v: tel["clocks.gr"] ? `${tel["clocks.gr"]} / ${tel["clocks.mem"]} MHz` : "" }), SP_JSX.jsx(Row, { k: "VRAM", v: tel["memory.used"] ? `${tel["memory.used"]} / ${tel["memory.total"]} MiB` : "" }), SP_JSX.jsx(Row, { k: "Load", v: tel["utilization.gpu"] ? `${tel["utilization.gpu"]} %` : "" }), SP_JSX.jsx(Row, { k: "Fan", v: tel["fan.speed"] && tel["fan.speed"] !== "[N/A]" ? `${tel["fan.speed"]} %` : "" })] })) }), !s.present ? null : controlsOk ? (SP_JSX.jsxs(DFL.PanelSection, { title: "Power controls", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.SliderField, { label: "Power limit (W)", value: plNow, min: plMin, max: plMax, step: 5, showValue: true, onChange: setPl }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || pl === null, onClick: () => run(() => setPowerLimit(plNow)), children: "Apply power limit" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.SliderField, { label: "Core clock offset (MHz)", value: off, min: -300, max: 300, step: 15, showValue: true, onChange: setOff }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => run(() => setCoreOffset(off)), children: "Apply offset" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => { setOff(0); setPl(null); run(resetClocks); }, children: "Reset clocks" }) }), msg && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: msg }) })] })) : (SP_JSX.jsx(DFL.PanelSection, { title: "Power controls", children: SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Available when Game Mode runs on the eGPU. On the handheld GPU, Game Mode's own performance menu applies." }) }) }))] })), tab === "setup" && (SP_JSX.jsxs(DFL.PanelSection, { title: "System integration", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px" }, children: su ? (su.installed_version ? (behind ? "Installed — press Install to finish updating" : "Installed") : "Not installed") : "…" }) }), su?.untested && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["Hardware: ", su.untested.split("\n").join("; "), ". ", su.accepted_untested ? "Risk notice accepted." : "Risk notice not accepted yet."] }) }), su?.cmdline_missing && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.8 }, children: ["Kernel parameters not active: ", su.cmdline_missing] }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: "Reinstalls everything the first run installs. Safe to run again." }) }), su?.busy && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(Progress, { pct: su.progress, title: "Installing", step: su.step, started: su.started, expect: su.expect }) }), su && !su.busy && su.rc !== null && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: su.rc === 0 ? "#4caf50" : "#ff6b6b" }, children: su.rc === 0 ? "Finished." : `Failed (rc ${su.rc}).` }) }), !su?.installed_version && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.9 }, children: [SP_JSX.jsx("b", { children: "Which eGPU will you connect?" }), " Pick one now - it only decides whether the NVIDIA driver is built. The eGPU does not need to be plugged in, and you can run the other install later if you change cards."] }) })), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => { if (confirmSetup === "install") {
                                setConfirmSetup("");
                                run(() => installSystem(false));
                            }
                            else
                                setConfirmSetup("install"); }, children: confirmSetup === "install"
                                ? "Press again to confirm"
                                : (su?.installed_version ? "Reinstall / update system integration" : "NVIDIA eGPU - install (builds the driver)") }) }), !su?.installed_version && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.7 }, children: "Builds the patched NVIDIA driver and the gamescope scan-out fix. Takes several minutes." }) })), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => { if (confirmSetup === "amd") {
                                setConfirmSetup("");
                                run(() => installSystem(false, "amd"));
                            }
                            else
                                setConfirmSetup("amd"); }, children: confirmSetup === "amd"
                                ? "Press again to confirm"
                                : (su?.installed_version ? "Switch to the AMD / Intel install (no NVIDIA driver)" : "AMD / Intel eGPU - install (no driver build)") }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.7 }, children: "Skips the NVIDIA driver build and the NVIDIA-only gamescope fix. Keeps hot-plug, safe detach, cable-pull recovery, audio follow and the flood protections. Beta: not yet tested on real AMD or Intel hardware." }) }), su?.installed_version && su.installed_vendor === "amd" && su.egpu_on_bus === "nvidia" && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: "#ffb300" }, children: "An NVIDIA eGPU is connected, but this machine was set up with the AMD install, which skips the NVIDIA driver. Run the NVIDIA install above to add it." }) })), su?.installed_version && su.installed_vendor !== "amd" && (su.egpu_on_bus === "amd" || su.egpu_on_bus === "intel") && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: "#ffb300" }, children: "A non-NVIDIA eGPU is connected. The NVIDIA driver this install built is not used by it - the AMD / Intel install above suits this machine better." }) })), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy || !su?.installed_version || egpuMounted, onClick: () => { if (confirmSetup === "uninstall") {
                                setConfirmSetup("");
                                run(uninstallSystem);
                            }
                            else
                                setConfirmSetup("uninstall"); }, children: confirmSetup === "uninstall" ? "Press again to confirm uninstall" : "Uninstall system integration" }) }), egpuMounted && su?.installed_version && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "11px", opacity: 0.7 }, children: "Safe Detach the eGPU first: the system files cannot be removed while its driver is running." }) }), su?.log && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "10px", whiteSpace: "pre-wrap", opacity: 0.8 }, children: su.log }) })] })), tab === "setup" && tr?.available && (SP_JSX.jsxs(DFL.PanelSection, { title: "Beta driver (advanced)", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs("div", { style: { fontSize: "12px", opacity: 0.85 }, children: ["Tested driver: ", tr.tested, ". Beta: ", tr.beta, ", with the same eGPU patches ported to it. Running now: ", tr.installed || "not installed", "."] }) }), tr.message && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", color: tr.state === "failed" ? "#ff6b6b" : tr.state === "kept" ? "#4caf50" : "#f0b429" }, children: tr.message }) }), tr.state !== "kept" && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs(DFL.ButtonItem, { layout: "below", disabled: busy || tr.running || !!su?.busy || gameUp || !s?.game_mode, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: `Try beta driver ${tr.beta}`, strDescription: `For testers. The eGPU is safely detached, the beta NVIDIA driver ${tr.beta} is downloaded from NVIDIA (about 530 MB) and built on this device (10-20 minutes, about 6 GB free space needed while building), then the eGPU is attached with it and checked. If it does not come up, the tested driver ${tr.tested} is put back and attached again by itself. If the machine resets or hangs during the test, the tested driver is put back at the next boot, before the eGPU is used. Keep the charger and the eGPU connected. Everything is logged to /var/log/egpu-driver-trial.log.`, strOKButtonText: "Try the beta driver", bDestructiveWarning: true, onOK: () => run(startTrial) })), children: ["Try beta driver ", tr.beta] }) })), (tr.state === "kept" || (tr.installed && tr.installed !== tr.tested)) && (SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsxs(DFL.ButtonItem, { layout: "below", disabled: busy || tr.running || gameUp || !s?.game_mode, onClick: () => DFL.showModal(SP_JSX.jsx(DFL.ConfirmModal, { strTitle: `Return to ${tr.tested}`, strDescription: `The eGPU is safely detached, the tested driver ${tr.tested} is put back (offline, a few minutes) and the eGPU is attached again.`, strOKButtonText: "Return", onOK: () => run(revertTrial) })), children: ["Return to the tested driver ", tr.tested] }) })), tr.log && SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "10px", whiteSpace: "pre-wrap", opacity: 0.8 }, children: tr.log }) })] })), tab === "setup" && (SP_JSX.jsxs(DFL.PanelSection, { title: "Updates", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ToggleField, { label: "Automatic updates", description: "Off (default): a new release is only announced here and you decide when to install it. On: it installs by itself when no game is running.", checked: !!up?.auto_update, onChange: (v) => run(() => setAutoUpdate(v)) }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy || !!su?.busy, onClick: () => run(() => checkUpdate(false)), children: "Check for updates now" }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: up ? (up.available ? `Available: ${up.available}` : (up.checked ? "Up to date." : "Not checked yet.")) + (up.last_error ? ` ${up.last_error}` : "") : "…" }) })] })), tab === "setup" && (SP_JSX.jsxs(DFL.PanelSection, { title: "Extras (testing)", children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ToggleField, { label: "TV control tricks", description: "Off by default. Choosing the TV for Game Mode turns it on and switches it to the eGPU's HDMI input; while it shows live TV or another input, the desktop leaves it out. LG webOS TVs over the network for now.", checked: !!tv?.enabled, onChange: (v) => run(() => setTvControl(v)) }) }), tv?.enabled && (SP_JSX.jsxs(SP_JSX.Fragment, { children: [SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx("div", { style: { fontSize: "12px", opacity: 0.8 }, children: tv.paired.length ? `Paired: ${tv.paired.join(", ")}` : "No TV paired yet." }) }), SP_JSX.jsx(DFL.PanelSectionRow, { children: SP_JSX.jsx(DFL.ButtonItem, { layout: "below", disabled: busy, onClick: () => { setMsg("Choose Allow on the TV's prompt…"); run(pairTv); }, children: tv.paired.length ? "Pair again" : "Find and pair TV" }) })] }))] }))] }));
}
var index = definePlugin(() => {
    // the finish line must reach the user even when the menu was closed or Decky restarted (plugin update) meanwhile
    const notices = setInterval(async () => {
        try {
            const t = await popNotice();
            if (t)
                toaster.toast({ title: "EGPU Buddy", body: t, duration: 15000 });
        }
        catch { /* backend not up yet */ }
        try {
            await maybeShowTrial();
        }
        catch { /* backend not up yet */ }
        try {
            await maybeOfferScreen();
        }
        catch { /* backend not up yet */ }
    }, 5000);
    return {
        name: "EGPU Buddy",
        title: SP_JSX.jsx("div", { className: DFL.staticClasses.Title, children: "EGPU Buddy" }),
        content: SP_JSX.jsx(Content, {}),
        icon: SP_JSX.jsx(FaPlug, {}),
        onDismount() { clearInterval(notices); },
    };
});

export { index as default };
//# sourceMappingURL=index.js.map
