pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Item {
    id: root

    readonly property var defaults: ({
            debounceDelay: 300,
            runtimes: [
                {
                    id: "docker",
                    label: "Docker",
                    binary: "docker",
                    enabled: true
                },
                {
                    id: "podman",
                    label: "Podman",
                    binary: "podman",
                    enabled: true
                }
            ],
            terminalApp: "alacritty --hold",
            shellPath: "/bin/sh",
            pollingInterval: 0
        })

    readonly property string pluginId: "gantry"

    property bool systemdRunAvailable: false
    property var runtimeAvailable: ({})
    property int debounceDelay: defaults.debounceDelay
    property var runtimes: defaults.runtimes
    property string terminalApp: defaults.terminalApp
    property string shellPath: defaults.shellPath
    property int pollingInterval: defaults.pollingInterval

    readonly property var enabledRuntimes: runtimes.filter(rt => rt.enabled)

    readonly property bool anyAvailable: Object.keys(runtimeAvailable).some(id => runtimeAvailable[id])

    // Settings are user-editable JSON; a half-written entry must not poison the
    // rest of the list, so every field falls back to a sane value.
    function normalizeRuntimes(list) {
        if (!Array.isArray(list))
            return defaults.runtimes;

        const normalized = list.filter(rt => rt && rt.id).map(rt => ({
                    id: String(rt.id),
                    label: rt.label ? String(rt.label) : String(rt.id),
                    binary: rt.binary ? String(rt.binary) : String(rt.id),
                    enabled: rt.enabled !== false
                }));

        return normalized.length > 0 ? normalized : defaults.runtimes;
    }

    function loadSettings() {
        const load = key => PluginService.loadPluginData(pluginId, key) || defaults[key];
        debounceDelay = load("debounceDelay");
        runtimes = normalizeRuntimes(load("runtimes"));
        terminalApp = load("terminalApp");
        shellPath = load("shellPath");
        pollingInterval = load("pollingInterval");

        refresh();
    }

    Component.onCompleted: {
        loadSettings();
        initialize();
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pluginId) {
            if (pluginId === root.pluginId) {
                loadSettings();
            }
        }
    }

    function eventCommandFor(rt) {
        return [rt.binary, "events", "--format", "json", "--filter", "type=container"];
    }

    // Single and global on purpose: an event from any runtime schedules one full
    // refresh, rather than each listener refreshing on its own.
    property var debounceTimer: Timer {
        interval: root.debounceDelay
        running: false
        repeat: false
        onTriggered: fetchContainers()
    }

    // One listener per enabled runtime. The Instantiator rebuilds them whenever
    // the runtime list changes, and each delegate owns its restart timer, so a
    // Podman that keeps dying cannot take the Docker listener down with it.
    property var eventListeners: Instantiator {
        model: root.enabledRuntimes

        delegate: QtObject {
            id: listener

            required property var modelData

            readonly property var eventsProcess: Process {
                command: root.eventCommandFor(listener.modelData)
                running: true

                stdout: SplitParser {
                    onRead: data => {
                        try {
                            const event = JSON.parse(data);
                            const action = event.Status || event.status;

                            if (["start", "stop", "die", "died", "kill", "restart", "pause", "unpause", "create", "destroy", "remove", "cleanup"].includes(action)) {
                                console.log(`Gantry[${listener.modelData.id}]: container event - ${action}`);
                                root.debounceTimer.restart();
                            }
                        } catch (e) {
                            console.error(`Gantry[${listener.modelData.id}]: failed to parse event:`, e, data);
                        }
                    }
                }

                onRunningChanged: {
                    if (!running) {
                        console.log(`Gantry[${listener.modelData.id}]: events listener stopped`);
                        listener.restartTimer.start();
                    }
                }
            }

            readonly property var restartTimer: Timer {
                interval: 5000
                running: false
                repeat: false
                onTriggered: {
                    if (root.runtimeAvailable[listener.modelData.id]) {
                        console.log(`Gantry[${listener.modelData.id}]: restarting events listener`);
                        listener.eventsProcess.running = true;
                    }
                }
            }

            // The restart timer gives up on a runtime that was down at the time,
            // so a runtime that comes up later needs its listener started here.
            readonly property var availabilityWatcher: Connections {
                target: root
                function onRuntimeAvailableChanged() {
                    if (root.runtimeAvailable[listener.modelData.id] && !listener.eventsProcess.running) {
                        console.log(`Gantry[${listener.modelData.id}]: runtime came up, starting events listener`);
                        listener.eventsProcess.running = true;
                    }
                }
            }
        }
    }

    // A socket-activated daemon, or a slow first `podman info` after login, can
    // miss the startup check. Nothing else would ever check again, so keep
    // retrying while an enabled runtime is down. Longer than the check timeout,
    // so rounds do not overlap.
    property var retryTimer: Timer {
        interval: 30000
        running: root.enabledRuntimes.some(rt => !root.runtimeAvailable[rt.id])
        repeat: true
        onTriggered: refresh(true)
    }

    property var pollingTimer: Timer {
        interval: root.pollingInterval
        running: root.anyAvailable && root.pollingInterval > 0
        repeat: true
        onTriggered: {
            console.log("Gantry: Polling for container state updates");
            fetchContainers();
        }
    }

    function initialize() {
        Proc.runCommand(`${pluginId}.systemdRunCheck`, ["which", "systemd-run"], (stdout, exitCode) => {
            systemdRunAvailable = exitCode === 0;
        }, 100);

        refresh();
    }

    // Bumped on every refresh so callbacks from a superseded round can be told
    // apart and dropped, instead of decrementing the current round's counter.
    property int checkGeneration: 0

    // Timeout for the availability check. Proc's default of 10s is about what
    // a socket-activated dockerd takes to come up, so it was hit at login.
    readonly property int checkTimeout: 20000

    // onlyIfChanged skips the container fetch when availability is unchanged,
    // so the retry timer does not turn into polling for a runtime that is
    // simply not installed.
    function refresh(onlyIfChanged) {
        const targets = enabledRuntimes;
        const generation = ++checkGeneration;
        const results = {};
        let pending = targets.length;

        if (pending === 0) {
            console.log("Gantry: no runtime enabled");
            applyAvailability(generation, results, onlyIfChanged);
            return;
        }

        targets.forEach(rt => {
            // Wrapped in sh -c on purpose. A binary that does not exist never
            // starts, and Proc's callback is then never called at all -- which
            // would leave `pending` stuck above zero and freeze collection for
            // good. sh always exists and reports 127 instead.
            Proc.runCommand(`${pluginId}.check.${rt.id}`, ["sh", "-c", `${shellQuote(rt.binary)} info`], (stdout, exitCode) => {
                if (generation !== checkGeneration) {
                    console.log(`Gantry[${rt.id}]: stale availability check discarded`);
                    return;
                }

                results[rt.id] = exitCode === 0;
                console.log(`Gantry[${rt.id}]: ${exitCode === 0 ? "available" : `unavailable (exit ${exitCode})`}`);

                if (--pending === 0) {
                    applyAvailability(generation, results, onlyIfChanged);
                }
            }, 100, checkTimeout);
        });
    }

    // Key by key: results are filled in whatever order the checks finish.
    function availabilityDiffers(a, b) {
        const ids = Object.keys(a).concat(Object.keys(b));
        return ids.some(id => !!a[id] !== !!b[id]);
    }

    function applyAvailability(generation, results, onlyIfChanged) {
        if (generation !== checkGeneration) {
            return;
        }

        if (onlyIfChanged && !availabilityDiffers(results, root.runtimeAvailable)) {
            return;
        }

        root.runtimeAvailable = results;
        PluginService.setGlobalVar(pluginId, "runtimeAvailable", results);

        // Read from `results` rather than the anyAvailable binding, which may not
        // have re-evaluated yet at this point.
        if (Object.keys(results).some(id => results[id])) {
            fetchContainers();
        } else {
            console.log("Gantry: no runtime available, clearing containers");
            updateContainers();
        }
    }

    // Bumped per collection round, so answers from a superseded round can be
    // dropped instead of decrementing the current round's counter.
    property int fetchGeneration: 0

    function fetchContainers() {
        const targets = enabledRuntimes.filter(rt => runtimeAvailable[rt.id]);
        const generation = ++fetchGeneration;
        let collected = [];
        let pending = targets.length;

        if (pending === 0) {
            updateContainers();
            return;
        }

        targets.forEach(rt => {
            Proc.runCommand(`${pluginId}.inspect.${rt.id}`, ["sh", "-c", `${shellQuote(rt.binary)} container inspect $(${shellQuote(rt.binary)} container ls -aq)`], (stdout, exitCode) => {
                if (generation !== fetchGeneration) {
                    console.log(`Gantry[${rt.id}]: stale container fetch discarded`);
                    return;
                }

                // A non-zero exit means this runtime has no containers to list
                // -- `container inspect` with no ids fails. It is never a reason
                // to drop what the other runtimes reported.
                if (exitCode === 0) {
                    const parsed = parseContainers(stdout, rt);
                    console.log(`Gantry[${rt.id}]: ${parsed.length} container(s)`);
                    collected = collected.concat(parsed);
                } else {
                    console.log(`Gantry[${rt.id}]: no containers (exit ${exitCode})`);
                }

                if (--pending === 0) {
                    publishContainers(generation, collected);
                }
            }, 100);
        });
    }

    function parseContainers(stdout, rt) {
        let raw;
        try {
            raw = JSON.parse(stdout);
        } catch (e) {
            console.error(`Gantry[${rt.id}]: failed to parse inspect output:`, e);
            return [];
        }

        return raw.map(container => {
            try {
                const labels = container.Config?.Labels || {};
                const state = container.State?.Status || "";
                const startedAt = new Date(container.State?.StartedAt || 0).getTime();
                const finishedAt = new Date(container.State?.FinishedAt || 0).getTime();
                const lastActivity = Math.max(startedAt, finishedAt);

                const ports = [];
                const portBindings = container.NetworkSettings?.Ports || {};
                for (const [containerPort, hostBindings] of Object.entries(portBindings)) {
                    if (hostBindings && hostBindings.length > 0) {
                        hostBindings.forEach(binding => {
                            const hostPort = binding.HostPort;
                            const hostIp = binding.HostIp || "0.0.0.0";
                            if (hostPort) {
                                ports.push({
                                    containerPort: containerPort,
                                    hostPort: hostPort,
                                    hostIp: hostIp
                                });
                            }
                        });
                    }
                }

                // Podman omits the leading slash on Name, Docker keeps it.
                const name = container.Name?.replace(/^\//, "") || "";

                const mounts = (container.Mounts || []).map(m => ({
                            type: m.Type || "",
                            source: m.Name || m.Source || "",
                            destination: m.Destination || ""
                        })).filter(m => m.destination);

                return {
                    runtime: rt.id,
                    id: container.Id || "",
                    name: name,
                    // Names are only unique within one runtime, so anything that
                    // keys off a name across the merged list needs this instead.
                    key: `${rt.id}:${name}`,
                    status: `${state.charAt(0).toUpperCase() + state.slice(1)}`,
                    state: state,
                    image: container.Config?.Image || container.ImageName || "",
                    // Docker reports a paused container as Running, Podman does not.
                    // Paused is its own state here, so both runtimes agree.
                    isRunning: (container.State?.Running && !container.State?.Paused) || false,
                    isPaused: container.State?.Paused || false,
                    created: container.Created || "",
                    lastActivity: lastActivity,
                    startedAt: startedAt,
                    exitCode: container.State?.ExitCode ?? 0,
                    health: container.State?.Health?.Status || "",
                    restartCount: container.RestartCount || 0,
                    pod: container.Pod || "",
                    mounts: mounts,
                    networks: Object.keys(container.NetworkSettings?.Networks || {}),
                    ports: ports,
                    composeProject: labels["com.docker.compose.project"] || labels["io.podman.compose.project"] || "",
                    composeService: labels["com.docker.compose.service"] || labels["io.podman.compose.service"] || "",
                    composeNumber: labels["com.docker.compose.container-number"] || "",
                    composeWorkingDir: labels["com.docker.compose.project.working_dir"] || "",
                    composeConfigFiles: labels["com.docker.compose.project.config_files"] || "compose.yaml"
                };
            } catch (e) {
                console.error(`Gantry[${rt.id}]: failed to parse container data:`, e, container);
                return null;
            }
        }).filter(c => c !== null);
    }

    function publishContainers(generation, collected) {
        if (generation !== fetchGeneration) {
            return;
        }

        // Sorted as one list. Runtime is a badge, not a grouping.
        const containers = collected.sort((a, b) => {
            const priority = {
                running: 1,
                paused: 2,
                default: 3
            };
            const aPriority = priority[a.state] || priority.default;
            const bPriority = priority[b.state] || priority.default;
            if (aPriority !== bPriority)
                return aPriority - bPriority;
            if (a.lastActivity !== b.lastActivity)
                return b.lastActivity - a.lastActivity;
            return a.name.localeCompare(b.name);
        });

        const projectMap = {};
        containers.forEach(container => {
            if (!container.composeProject) {
                return;
            }
            // Keyed by runtime too: the same project name can exist in both.
            const key = `${container.runtime}:${container.composeProject}`;
            if (!projectMap[key]) {
                projectMap[key] = {
                    key: key,
                    runtime: container.runtime,
                    name: container.composeProject,
                    containers: [],
                    runningCount: 0,
                    totalCount: 0,
                    workingDir: container.composeWorkingDir,
                    configFile: container.composeConfigFiles
                };
            }
            projectMap[key].containers.push(container);
            projectMap[key].totalCount++;
            if (container.isRunning) {
                projectMap[key].runningCount++;
            }
        });

        const projects = Object.values(projectMap).sort((a, b) => {
            if (a.runningCount !== b.runningCount)
                return b.runningCount - a.runningCount;
            if (a.name !== b.name)
                return a.name.localeCompare(b.name);
            return a.runtime.localeCompare(b.runtime);
        });

        updateContainers(containers, containers.filter(c => c.isRunning).length, projects);
    }

    function updateContainers(containers = [], runningContainers = 0, composeProjects = []) {
        PluginService.setGlobalVar(pluginId, "containers", containers);
        PluginService.setGlobalVar(pluginId, "runningContainers", runningContainers);
        PluginService.setGlobalVar(pluginId, "composeProjects", composeProjects);
    }

    // Resolves the binary for a runtime id, or "" if that runtime is unknown or
    // disabled. Callers must abort on "" and never substitute a default: running
    // `docker stop` against an id that belongs to Podman does nothing at best,
    // and stops an unrelated container with the same name at worst.
    function binaryFor(runtimeId, context) {
        if (!runtimeId) {
            console.error(`Gantry: ${context} requested without a runtime`);
            return "";
        }

        const rt = runtimes.find(r => r.id === runtimeId);
        if (!rt) {
            console.error(`Gantry[${runtimeId}]: ${context} refused, unknown runtime`);
            return "";
        }
        if (!rt.enabled) {
            console.error(`Gantry[${runtimeId}]: ${context} refused, runtime is disabled`);
            return "";
        }
        return rt.binary;
    }

    function shellQuote(value) {
        return `'${String(value).replace(/'/g, "'\\''")}'`;
    }

    function shellLine(argv) {
        return argv.map(shellQuote).join(" ");
    }

    // terminalApp is left unquoted on purpose: it is a command line with its own
    // arguments (e.g. "alacritty --hold"). Everything after -e is quoted.
    function openInTerminal(argv) {
        Quickshell.execDetached(["sh", "-c", `${terminalApp} -e ${shellLine(argv)}`]);
    }

    // Actions run through Proc rather than execDetached so the caller learns the
    // exit code and the runtime's own message. stderr is folded into stdout
    // because Proc only hands the callback stdout. systemd-run --user --scope
    // still moves the work into its own unit, so it outlives the shell, and
    // systemd-run reports the command's exit status back. No timeout: Proc kills
    // the process when it fires, and a compose restart or a slow stop can take minutes.
    // No id either: Proc debounces by id, so a second action on the same target
    // would silently replace the first and its callback would never come back.
    function runAction(argv, onDone) {
        const wrapped = systemdRunAvailable ? ["systemd-run", "--user", "--scope", "--quiet", "--", ...argv] : argv;
        const line = `${shellLine(wrapped)} 2>&1`;

        Proc.runCommand(null, ["sh", "-c", line], (output, exitCode) => {
            const message = String(output || "").trim();
            if (exitCode !== 0) {
                console.error(`Gantry: command failed (exit ${exitCode}): ${message}`);
            }
            root.refresh();
            if (onDone) {
                onDone(exitCode === 0, message);
            }
        }, 0, Proc.noTimeout);
    }

    function executeAction(runtimeId, containerId, action, onDone) {
        const binary = binaryFor(runtimeId, `action '${action}'`);
        if (!binary) {
            return false;
        }

        const commands = {
            start: [binary, "start", containerId],
            stop: [binary, "stop", containerId],
            restart: [binary, "restart", containerId],
            pause: [binary, "pause", containerId],
            unpause: [binary, "unpause", containerId]
        };

        if (commands[action]) {
            console.log(`Gantry[${runtimeId}]: ${action} ${containerId}`);
            runAction(commands[action], onDone);
            return true;
        }
        return false;
    }

    function executeComposeAction(runtimeId, workingDir, configFile, action, onDone) {
        const binary = binaryFor(runtimeId, `compose action '${action}'`);
        if (!binary) {
            return false;
        }

        if (!workingDir) {
            console.error(`Gantry[${runtimeId}]: cannot execute compose action without working directory`);
            return false;
        }

        // The config_files label joins every -f the project was started with
        // using commas, and compose will not split a single -f on them.
        const compose = [binary, "compose"];
        String(configFile || "").split(",").filter(f => f).forEach(f => compose.push("-f", f));
        const composeCommands = {
            restart: [...compose, "restart"],
            stop: [...compose, "stop"],
            start: [...compose, "start"],
            logs: null
        };

        if (action === "logs") {
            console.log(`Gantry[${runtimeId}]: compose logs in ${workingDir}`);
            openInTerminal(["sh", "-c", `cd ${shellQuote(workingDir)} && ${shellLine([...compose, "logs", "-f"])}`]);
            return true;
        }

        if (composeCommands[action]) {
            console.log(`Gantry[${runtimeId}]: compose ${action} in ${workingDir}`);
            runAction(["sh", "-c", `cd ${shellQuote(workingDir)} && ${shellLine(composeCommands[action])}`], onDone);
            return true;
        }
        return false;
    }

    function openLogs(runtimeId, containerId) {
        const binary = binaryFor(runtimeId, "logs");
        if (!binary) {
            return false;
        }
        console.log(`Gantry[${runtimeId}]: logs ${containerId}`);
        openInTerminal([binary, "logs", "-f", containerId]);
        return true;
    }

    function openExec(runtimeId, containerId) {
        const binary = binaryFor(runtimeId, "exec");
        if (!binary) {
            return false;
        }
        console.log(`Gantry[${runtimeId}]: exec ${containerId}`);
        openInTerminal([binary, "exec", "-it", containerId, shellPath]);
        return true;
    }
}
