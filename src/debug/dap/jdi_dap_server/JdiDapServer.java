import com.sun.jdi.*;
import com.sun.jdi.connect.*;
import com.sun.jdi.event.*;
import com.sun.jdi.request.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * A single-file JDI-based DAP (Debug Adapter Protocol) server.
 * Zero external dependencies — requires only a JDK (java + javac).
 * Communicates over stdio using Content-Length framed JSON messages.
 *
 * Threading model:
 *   Main thread — reads DAP requests from stdin, dispatches handlers, writes responses/events.
 *                 All JDI mutation happens here (VM is suspended during inspection).
 *   JDI event thread (daemon) — blocks on EventQueue.remove(), posts events to a
 *                 LinkedBlockingQueue. Never calls JDI mutation methods.
 */
public class JdiDapServer {

    // ── Entry Point ─────────────────────────────────────────────────────

    public static void main(String[] args) throws Exception {
        JdiDapServer server = new JdiDapServer(System.in, System.out);
        server.run();
    }

    private final DapTransport transport;
    private final DapDispatcher dispatcher;

    JdiDapServer(InputStream in, OutputStream out) {
        this.transport = new DapTransport(in, out);
        this.dispatcher = new DapDispatcher(transport);
    }

    void run() {
        while (true) {
            try {
                String message = transport.readMessage();
                if (message == null) break;
                Map<String, Object> request = JsonParser.parse(message);
                if (request == null) continue;
                String type = Json.getString(request, "type");
                if ("request".equals(type)) {
                    dispatcher.dispatch(request);
                }
            } catch (IOException e) {
                break;
            } catch (Exception e) {
                // Swallow and continue
            }
        }
        dispatcher.shutdown();
    }

    // ── DapTransport ────────────────────────────────────────────────────

    static class DapTransport {
        private final BufferedInputStream in;
        private final OutputStream out;

        DapTransport(InputStream in, OutputStream out) {
            this.in = new BufferedInputStream(in);
            this.out = out;
        }

        synchronized String readMessage() throws IOException {
            // Read headers
            int contentLength = -1;
            StringBuilder headerLine = new StringBuilder();
            while (true) {
                int b = in.read();
                if (b == -1) return null;
                if (b == '\r') {
                    b = in.read();
                    if (b == '\n') {
                        String header = headerLine.toString();
                        if (header.isEmpty()) break;
                        if (header.startsWith("Content-Length:")) {
                            contentLength = Integer.parseInt(header.substring(15).trim());
                        }
                        headerLine.setLength(0);
                    }
                } else {
                    headerLine.append((char) b);
                }
            }
            if (contentLength <= 0) return null;
            byte[] body = new byte[contentLength];
            int offset = 0;
            while (offset < contentLength) {
                int n = in.read(body, offset, contentLength - offset);
                if (n == -1) return null;
                offset += n;
            }
            return new String(body, StandardCharsets.UTF_8);
        }

        synchronized void sendMessage(String json) {
            try {
                byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
                String header = "Content-Length: " + bytes.length + "\r\n\r\n";
                out.write(header.getBytes(StandardCharsets.UTF_8));
                out.write(bytes);
                out.flush();
            } catch (IOException e) {
                // Client disconnected
            }
        }

        void sendResponse(int requestSeq, String command, boolean success, Object body) {
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("seq", 0);
            resp.put("type", "response");
            resp.put("request_seq", requestSeq);
            resp.put("success", success);
            resp.put("command", command);
            if (body != null) {
                resp.put("body", body);
            }
            sendMessage(Json.serialize(resp));
        }

        void sendErrorResponse(int requestSeq, String command, String message) {
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("seq", 0);
            resp.put("type", "response");
            resp.put("request_seq", requestSeq);
            resp.put("success", false);
            resp.put("command", command);
            resp.put("message", message);
            sendMessage(Json.serialize(resp));
        }

        void sendEvent(String event, Map<String, Object> body) {
            Map<String, Object> evt = new LinkedHashMap<>();
            evt.put("seq", 0);
            evt.put("type", "event");
            evt.put("event", event);
            if (body != null) {
                evt.put("body", body);
            }
            sendMessage(Json.serialize(evt));
        }
    }

    // ── JsonParser ──────────────────────────────────────────────────────

    static class JsonParser {
        private final String src;
        private int pos;

        private JsonParser(String src) {
            this.src = src;
            this.pos = 0;
        }

        @SuppressWarnings("unchecked")
        static Map<String, Object> parse(String json) {
            try {
                JsonParser p = new JsonParser(json);
                Object val = p.parseValue();
                if (val instanceof Map) return (Map<String, Object>) val;
                return null;
            } catch (Exception e) {
                return null;
            }
        }

        static Object parseAny(String json) {
            try {
                JsonParser p = new JsonParser(json);
                return p.parseValue();
            } catch (Exception e) {
                return null;
            }
        }

        private void skipWhitespace() {
            while (pos < src.length() && " \t\r\n".indexOf(src.charAt(pos)) >= 0) pos++;
        }

        private Object parseValue() {
            skipWhitespace();
            if (pos >= src.length()) return null;
            char c = src.charAt(pos);
            if (c == '{') return parseObject();
            if (c == '[') return parseArray();
            if (c == '"') return parseString();
            if (c == 't') { pos += 4; return Boolean.TRUE; }
            if (c == 'f') { pos += 5; return Boolean.FALSE; }
            if (c == 'n') { pos += 4; return null; }
            return parseNumber();
        }

        private Map<String, Object> parseObject() {
            Map<String, Object> map = new LinkedHashMap<>();
            pos++; // skip {
            skipWhitespace();
            if (pos < src.length() && src.charAt(pos) == '}') { pos++; return map; }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                pos++; // skip :
                Object val = parseValue();
                map.put(key, val);
                skipWhitespace();
                if (pos < src.length() && src.charAt(pos) == ',') { pos++; continue; }
                break;
            }
            if (pos < src.length() && src.charAt(pos) == '}') pos++;
            return map;
        }

        private List<Object> parseArray() {
            List<Object> list = new ArrayList<>();
            pos++; // skip [
            skipWhitespace();
            if (pos < src.length() && src.charAt(pos) == ']') { pos++; return list; }
            while (true) {
                list.add(parseValue());
                skipWhitespace();
                if (pos < src.length() && src.charAt(pos) == ',') { pos++; continue; }
                break;
            }
            if (pos < src.length() && src.charAt(pos) == ']') pos++;
            return list;
        }

        private String parseString() {
            pos++; // skip opening "
            StringBuilder sb = new StringBuilder();
            while (pos < src.length()) {
                char c = src.charAt(pos++);
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    if (pos >= src.length()) break;
                    char esc = src.charAt(pos++);
                    switch (esc) {
                        case '"': sb.append('"'); break;
                        case '\\': sb.append('\\'); break;
                        case '/': sb.append('/'); break;
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'u':
                            if (pos + 4 <= src.length()) {
                                sb.append((char) Integer.parseInt(src.substring(pos, pos + 4), 16));
                                pos += 4;
                            }
                            break;
                        default: sb.append(esc); break;
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        private Number parseNumber() {
            int start = pos;
            boolean isDouble = false;
            if (pos < src.length() && src.charAt(pos) == '-') pos++;
            while (pos < src.length() && Character.isDigit(src.charAt(pos))) pos++;
            if (pos < src.length() && src.charAt(pos) == '.') { isDouble = true; pos++; while (pos < src.length() && Character.isDigit(src.charAt(pos))) pos++; }
            if (pos < src.length() && (src.charAt(pos) == 'e' || src.charAt(pos) == 'E')) { isDouble = true; pos++; if (pos < src.length() && (src.charAt(pos) == '+' || src.charAt(pos) == '-')) pos++; while (pos < src.length() && Character.isDigit(src.charAt(pos))) pos++; }
            String num = src.substring(start, pos);
            if (isDouble) return Double.parseDouble(num);
            long val = Long.parseLong(num);
            if (val >= Integer.MIN_VALUE && val <= Integer.MAX_VALUE) return (int) val;
            return val;
        }
    }

    // ── Json Builder ────────────────────────────────────────────────────

    static class Json {
        @SuppressWarnings("unchecked")
        static String serialize(Object obj) {
            StringBuilder sb = new StringBuilder();
            write(sb, obj);
            return sb.toString();
        }

        @SuppressWarnings("unchecked")
        static void write(StringBuilder sb, Object obj) {
            if (obj == null) { sb.append("null"); return; }
            if (obj instanceof Boolean) { sb.append(obj); return; }
            if (obj instanceof Number) {
                Number n = (Number) obj;
                if (n instanceof Double || n instanceof Float) {
                    double d = n.doubleValue();
                    if (d == Math.floor(d) && !Double.isInfinite(d)) {
                        sb.append((long) d);
                    } else {
                        sb.append(d);
                    }
                } else {
                    sb.append(n);
                }
                return;
            }
            if (obj instanceof String) { writeString(sb, (String) obj); return; }
            if (obj instanceof Map) {
                Map<String, Object> map = (Map<String, Object>) obj;
                sb.append('{');
                boolean first = true;
                for (Map.Entry<String, Object> entry : map.entrySet()) {
                    if (!first) sb.append(',');
                    first = false;
                    writeString(sb, entry.getKey());
                    sb.append(':');
                    write(sb, entry.getValue());
                }
                sb.append('}');
                return;
            }
            if (obj instanceof List) {
                List<Object> list = (List<Object>) obj;
                sb.append('[');
                for (int i = 0; i < list.size(); i++) {
                    if (i > 0) sb.append(',');
                    write(sb, list.get(i));
                }
                sb.append(']');
                return;
            }
            if (obj instanceof int[]) {
                int[] arr = (int[]) obj;
                sb.append('[');
                for (int i = 0; i < arr.length; i++) {
                    if (i > 0) sb.append(',');
                    sb.append(arr[i]);
                }
                sb.append(']');
                return;
            }
            // Fallback
            writeString(sb, obj.toString());
        }

        static void writeString(StringBuilder sb, String s) {
            sb.append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    case '\b': sb.append("\\b"); break;
                    case '\f': sb.append("\\f"); break;
                    default:
                        if (c < 0x20) {
                            sb.append(String.format("\\u%04x", (int) c));
                        } else {
                            sb.append(c);
                        }
                }
            }
            sb.append('"');
        }

        static String getString(Map<String, Object> map, String key) {
            Object v = map.get(key);
            return v instanceof String ? (String) v : null;
        }

        static int getInt(Map<String, Object> map, String key, int def) {
            Object v = map.get(key);
            if (v instanceof Number) return ((Number) v).intValue();
            return def;
        }

        static long getLong(Map<String, Object> map, String key, long def) {
            Object v = map.get(key);
            if (v instanceof Number) return ((Number) v).longValue();
            return def;
        }

        static boolean getBool(Map<String, Object> map, String key, boolean def) {
            Object v = map.get(key);
            if (v instanceof Boolean) return (Boolean) v;
            return def;
        }

        @SuppressWarnings("unchecked")
        static Map<String, Object> getObject(Map<String, Object> map, String key) {
            Object v = map.get(key);
            if (v instanceof Map) return (Map<String, Object>) v;
            return null;
        }

        @SuppressWarnings("unchecked")
        static List<Object> getArray(Map<String, Object> map, String key) {
            Object v = map.get(key);
            if (v instanceof List) return (List<Object>) v;
            return null;
        }
    }

    // ── VariableRefPool ─────────────────────────────────────────────────

    static class VariableRefPool {
        private final Map<Integer, PoolEntry> refToEntry = new ConcurrentHashMap<>();
        private final AtomicInteger nextRef = new AtomicInteger(1);

        static class PoolEntry {
            final Object jdiValue; // ObjectReference, ArrayReference, StackFrame scope, etc.
            final String scope;    // "locals", "arguments", "this", etc. — null for objects
            final ThreadReference thread;
            final int frameIndex;

            PoolEntry(Object jdiValue, String scope, ThreadReference thread, int frameIndex) {
                this.jdiValue = jdiValue;
                this.scope = scope;
                this.thread = thread;
                this.frameIndex = frameIndex;
            }
        }

        int allocRef(Object jdiValue, String scope, ThreadReference thread, int frameIndex) {
            int ref = nextRef.getAndIncrement();
            refToEntry.put(ref, new PoolEntry(jdiValue, scope, thread, frameIndex));
            return ref;
        }

        PoolEntry getEntry(int ref) {
            return refToEntry.get(ref);
        }

        void clear() {
            refToEntry.clear();
            nextRef.set(1);
        }
    }

    // ── JdiEventThread ──────────────────────────────────────────────────

    static class JdiEventThread extends Thread {
        private final VirtualMachine vm;
        final BlockingQueue<EventSet> eventQueue = new LinkedBlockingQueue<>();
        private volatile boolean running = true;

        JdiEventThread(VirtualMachine vm) {
            super("JdiEventThread");
            setDaemon(true);
            this.vm = vm;
        }

        void shutdown() {
            running = false;
            this.interrupt();
        }

        @Override
        public void run() {
            try {
                EventQueue queue = vm.eventQueue();
                while (running) {
                    EventSet eventSet = queue.remove();
                    eventQueue.put(eventSet);
                }
            } catch (InterruptedException e) {
                // Normal shutdown
            } catch (VMDisconnectedException e) {
                // VM exited
            }
        }
    }

    // ── BreakpointManager ───────────────────────────────────────────────

    static class BreakpointManager {
        private final Map<String, List<BpEntry>> fileBreakpoints = new HashMap<>();
        private final List<FuncBpEntry> functionBreakpoints = new ArrayList<>();
        private final List<String> exceptionFilters = new ArrayList<>();
        private final Map<String, List<BpEntry>> pendingBreakpoints = new HashMap<>();
        private int nextId = 1;
        private VirtualMachine vm;

        static class BpEntry {
            int id;
            String file;
            int line;
            String condition;
            String hitCondition;
            String logMessage;
            boolean verified;
            BreakpointRequest request;
            int hitCount;

            BpEntry(int id, String file, int line, String condition, String hitCondition, String logMessage) {
                this.id = id;
                this.file = file;
                this.line = line;
                this.condition = condition;
                this.hitCondition = hitCondition;
                this.logMessage = logMessage;
            }
        }

        static class FuncBpEntry {
            int id;
            String functionName;
            String condition;
            boolean verified;
            List<BreakpointRequest> requests = new ArrayList<>();

            FuncBpEntry(int id, String functionName, String condition) {
                this.id = id;
                this.functionName = functionName;
                this.condition = condition;
            }
        }

        void setVm(VirtualMachine vm) {
            this.vm = vm;
        }

        void clearAll() {
            fileBreakpoints.clear();
            pendingBreakpoints.clear();
            functionBreakpoints.clear();
            exceptionFilters.clear();
        }

        int nextBpId() {
            return nextId++;
        }

        List<Map<String, Object>> setBreakpoints(String sourcePath, List<Map<String, Object>> bpSpecs) {
            // Remove old breakpoints for this file
            List<BpEntry> old = fileBreakpoints.remove(sourcePath);
            if (old != null) {
                for (BpEntry bp : old) {
                    if (bp.request != null) {
                        try {
                            bp.request.disable();
                            vm.eventRequestManager().deleteEventRequest(bp.request);
                        } catch (Exception e) {
                            // Stale request from a previous VM — ignore
                        }
                    }
                }
            }
            // Remove pending breakpoints for this file
            pendingBreakpoints.remove(sourcePath);

            List<BpEntry> entries = new ArrayList<>();
            List<Map<String, Object>> results = new ArrayList<>();

            for (Map<String, Object> spec : bpSpecs) {
                int line = Json.getInt(spec, "line", 0);
                String condition = Json.getString(spec, "condition");
                String hitCondition = Json.getString(spec, "hitCondition");
                String logMessage = Json.getString(spec, "logMessage");
                int id = nextBpId();
                BpEntry entry = new BpEntry(id, sourcePath, line, condition, hitCondition, logMessage);
                entries.add(entry);

                boolean resolved = tryResolveBreakpoint(entry);
                Map<String, Object> result = new LinkedHashMap<>();
                result.put("id", id);
                result.put("verified", resolved);
                result.put("line", line);
                if (!resolved) {
                    result.put("message", "Class not yet loaded");
                    // Add to pending for deferred resolution
                    pendingBreakpoints.computeIfAbsent(sourcePath, k -> new ArrayList<>()).add(entry);
                }
                results.add(result);
            }
            fileBreakpoints.put(sourcePath, entries);
            return results;
        }

        private boolean tryResolveBreakpoint(BpEntry entry) {
            if (vm == null) return false;
            // Try to find loaded classes matching this source file
            String fileName = Paths.get(entry.file).getFileName().toString();
            for (ReferenceType refType : vm.allClasses()) {
                try {
                    String srcName = refType.sourceName();
                    if (srcName.equals(fileName)) {
                        List<Location> locs = refType.locationsOfLine(entry.line);
                        if (!locs.isEmpty()) {
                            BreakpointRequest req = vm.eventRequestManager().createBreakpointRequest(locs.get(0));
                            req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                            req.enable();
                            entry.request = req;
                            entry.verified = true;
                            return true;
                        }
                    }
                } catch (AbsentInformationException | ClassNotPreparedException e) {
                    // Continue
                }
            }
            return false;
        }

        void resolveDeferred(ReferenceType refType, DapTransport transport) {
            try {
                String srcName = refType.sourceName();
                // Find all pending breakpoints whose filename matches
                for (Map.Entry<String, List<BpEntry>> mapEntry : pendingBreakpoints.entrySet()) {
                    String bpFile = mapEntry.getKey();
                    String bpFileName = Paths.get(bpFile).getFileName().toString();
                    if (!bpFileName.equals(srcName)) continue;

                    Iterator<BpEntry> it = mapEntry.getValue().iterator();
                    while (it.hasNext()) {
                        BpEntry bp = it.next();
                        if (bp.verified) { it.remove(); continue; }
                        try {
                            List<Location> locs = refType.locationsOfLine(bp.line);
                            if (!locs.isEmpty()) {
                                BreakpointRequest req = vm.eventRequestManager().createBreakpointRequest(locs.get(0));
                                req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                                req.enable();
                                bp.request = req;
                                bp.verified = true;
                                it.remove();

                                // Emit breakpoint changed event
                                Map<String, Object> bpBody = new LinkedHashMap<>();
                                bpBody.put("reason", "changed");
                                Map<String, Object> bpInfo = new LinkedHashMap<>();
                                bpInfo.put("id", bp.id);
                                bpInfo.put("verified", true);
                                bpInfo.put("line", bp.line);
                                bpBody.put("breakpoint", bpInfo);
                                transport.sendEvent("breakpoint", bpBody);
                            }
                        } catch (AbsentInformationException e) {
                            // Still can't resolve
                        }
                    }
                }
            } catch (AbsentInformationException e) {
                // Can't get source name
            }
        }

        List<Map<String, Object>> setFunctionBreakpoints(List<Map<String, Object>> fbSpecs) {
            // Remove old function breakpoints
            for (FuncBpEntry fb : functionBreakpoints) {
                for (BreakpointRequest req : fb.requests) {
                    try {
                        req.disable();
                        vm.eventRequestManager().deleteEventRequest(req);
                    } catch (Exception e) {
                        // Stale request from a previous VM — ignore
                    }
                }
            }
            functionBreakpoints.clear();

            List<Map<String, Object>> results = new ArrayList<>();
            for (Map<String, Object> spec : fbSpecs) {
                String name = Json.getString(spec, "name");
                String condition = Json.getString(spec, "condition");
                int id = nextBpId();
                FuncBpEntry entry = new FuncBpEntry(id, name, condition);
                functionBreakpoints.add(entry);

                boolean resolved = tryResolveFunctionBreakpoint(entry);
                Map<String, Object> result = new LinkedHashMap<>();
                result.put("id", id);
                result.put("verified", resolved);
                if (!resolved) {
                    result.put("message", "Function not found in loaded classes");
                }
                results.add(result);
            }
            return results;
        }

        private boolean tryResolveFunctionBreakpoint(FuncBpEntry entry) {
            if (vm == null) return false;
            for (ReferenceType refType : vm.allClasses()) {
                for (Method method : refType.methods()) {
                    if (method.name().equals(entry.functionName) ||
                        (refType.name() + "." + method.name()).equals(entry.functionName)) {
                        try {
                            Location loc = method.location();
                            BreakpointRequest req = vm.eventRequestManager().createBreakpointRequest(loc);
                            req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                            req.enable();
                            entry.requests.add(req);
                            entry.verified = true;
                        } catch (Exception e) {
                            // Skip this method
                        }
                    }
                }
            }
            return entry.verified;
        }

        void setExceptionBreakpoints(List<String> filters) {
            // Remove old exception requests
            if (vm != null) {
                EventRequestManager erm = vm.eventRequestManager();
                for (ExceptionRequest req : new ArrayList<>(erm.exceptionRequests())) {
                    erm.deleteEventRequest(req);
                }
            }
            exceptionFilters.clear();
            exceptionFilters.addAll(filters);

            if (vm == null) return;
            boolean caught = filters.contains("caught");
            boolean uncaught = filters.contains("uncaught");
            if (caught || uncaught) {
                ExceptionRequest req = vm.eventRequestManager().createExceptionRequest(null, caught, uncaught);
                req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                req.enable();
            }
        }

        List<String> getExceptionFilters() {
            return exceptionFilters;
        }

        List<Map<String, Object>> listBreakpoints() {
            List<Map<String, Object>> results = new ArrayList<>();
            for (Map.Entry<String, List<BpEntry>> entry : fileBreakpoints.entrySet()) {
                for (BpEntry bp : entry.getValue()) {
                    Map<String, Object> m = new LinkedHashMap<>();
                    m.put("id", bp.id);
                    m.put("verified", bp.verified);
                    m.put("line", bp.line);
                    Map<String, Object> source = new LinkedHashMap<>();
                    source.put("path", bp.file);
                    m.put("source", source);
                    results.add(m);
                }
            }
            for (FuncBpEntry fb : functionBreakpoints) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("id", fb.id);
                m.put("verified", fb.verified);
                m.put("message", "Function: " + fb.functionName);
                results.add(m);
            }
            return results;
        }

        BpEntry findByRequest(BreakpointRequest req) {
            for (List<BpEntry> entries : fileBreakpoints.values()) {
                for (BpEntry bp : entries) {
                    if (bp.request == req) return bp;
                }
            }
            return null;
        }

        boolean shouldStop(BreakpointRequest req) {
            BpEntry bp = findByRequest(req);
            if (bp == null) return true;
            bp.hitCount++;

            // Check hit condition
            if (bp.hitCondition != null && !bp.hitCondition.isEmpty()) {
                try {
                    int target = Integer.parseInt(bp.hitCondition.replaceAll("[^0-9]", ""));
                    String op = bp.hitCondition.replaceAll("[0-9\\s]", "");
                    if (op.isEmpty() || op.equals("=") || op.equals("==")) {
                        if (bp.hitCount != target) return false;
                    } else if (op.equals(">")) {
                        if (bp.hitCount <= target) return false;
                    } else if (op.equals(">=")) {
                        if (bp.hitCount < target) return false;
                    } else if (op.equals("%")) {
                        if (bp.hitCount % target != 0) return false;
                    }
                } catch (NumberFormatException e) {
                    // Invalid hit condition — always stop
                }
            }

            return true;
        }

        boolean isLogpoint(BreakpointRequest req) {
            BpEntry bp = findByRequest(req);
            return bp != null && bp.logMessage != null && !bp.logMessage.isEmpty();
        }

        String getLogMessage(BreakpointRequest req) {
            BpEntry bp = findByRequest(req);
            return bp != null ? bp.logMessage : null;
        }

        String getCondition(BreakpointRequest req) {
            BpEntry bp = findByRequest(req);
            return bp != null ? bp.condition : null;
        }

        void setupClassPrepareRequests() {
            if (vm == null) return;
            // Request class prepare events for all classes so we can resolve
            // deferred breakpoints when new classes load.
            ClassPrepareRequest cpr = vm.eventRequestManager().createClassPrepareRequest();
            cpr.setSuspendPolicy(EventRequest.SUSPEND_ALL);
            cpr.enable();
        }

        void rearmAll() {
            if (vm == null) return;
            // Re-resolve all breakpoints
            for (Map.Entry<String, List<BpEntry>> entry : fileBreakpoints.entrySet()) {
                for (BpEntry bp : entry.getValue()) {
                    if (bp.request != null) {
                        try {
                            bp.request.disable();
                            vm.eventRequestManager().deleteEventRequest(bp.request);
                        } catch (Exception e) { /* ignore */ }
                        bp.request = null;
                    }
                    bp.verified = false;
                    bp.hitCount = 0;
                    tryResolveBreakpoint(bp);
                }
            }
            // Re-resolve function breakpoints
            for (FuncBpEntry fb : functionBreakpoints) {
                for (BreakpointRequest req : fb.requests) {
                    try {
                        req.disable();
                        vm.eventRequestManager().deleteEventRequest(req);
                    } catch (Exception e) { /* ignore */ }
                }
                fb.requests.clear();
                fb.verified = false;
                tryResolveFunctionBreakpoint(fb);
            }
            // Re-arm exception breakpoints
            setExceptionBreakpoints(new ArrayList<>(exceptionFilters));
            // Re-setup class prepare requests
            setupClassPrepareRequests();
        }

        List<Map<String, Object>> getBreakpointLocations(String sourcePath, int startLine, int endLine) {
            List<Map<String, Object>> results = new ArrayList<>();
            if (vm == null) return results;
            String fileName = Paths.get(sourcePath).getFileName().toString();
            for (ReferenceType refType : vm.allClasses()) {
                try {
                    if (!refType.sourceName().equals(fileName)) continue;
                    for (int line = startLine; line <= endLine; line++) {
                        List<Location> locs = refType.locationsOfLine(line);
                        if (!locs.isEmpty()) {
                            Map<String, Object> loc = new LinkedHashMap<>();
                            loc.put("line", line);
                            results.add(loc);
                        }
                    }
                } catch (AbsentInformationException e) {
                    // Skip
                }
            }
            return results;
        }
    }

    // ── ExpressionEvaluator ─────────────────────────────────────────────

    static class ExpressionEvaluator {

        static Value evaluate(String expression, ThreadReference thread, int frameIndex, VirtualMachine vm) throws Exception {
            StackFrame frame = thread.frame(frameIndex);
            expression = expression.trim();

            // Try simple variable first
            try {
                LocalVariable var = frame.visibleVariableByName(expression);
                if (var != null) return frame.getValue(var);
            } catch (AbsentInformationException | InvalidStackFrameException e) {
                // Fall through
            }

            // Try 'this'
            if ("this".equals(expression)) {
                return frame.thisObject();
            }

            // Try field access: a.b or a.b.c
            if (expression.contains(".") && !expression.contains("(")) {
                return evaluateFieldAccess(expression, frame, thread, vm);
            }

            // Try array indexing: a[i]
            if (expression.contains("[") && expression.endsWith("]")) {
                return evaluateArrayAccess(expression, frame, thread, vm);
            }

            // Try method call: obj.method() or method()
            if (expression.contains("(") && expression.endsWith(")")) {
                return evaluateMethodCall(expression, frame, thread, vm);
            }

            // Try arithmetic: a + b, a - b, a * b, a / b
            for (String op : new String[]{" + ", " - ", " * ", " / ", " % "}) {
                int idx = expression.lastIndexOf(op);
                if (idx > 0) {
                    String left = expression.substring(0, idx);
                    String right = expression.substring(idx + op.length());
                    Value leftVal = evaluate(left, thread, frameIndex, vm);
                    Value rightVal = evaluate(right, thread, frameIndex, vm);
                    return evaluateArithmetic(leftVal, rightVal, op.trim().charAt(0), vm);
                }
            }

            // Try comparison: a == b, a != b, a < b, etc.
            for (String op : new String[]{" == ", " != ", " <= ", " >= ", " < ", " > "}) {
                int idx = expression.indexOf(op);
                if (idx > 0) {
                    String left = expression.substring(0, idx);
                    String right = expression.substring(idx + op.length());
                    Value leftVal = evaluate(left, thread, frameIndex, vm);
                    Value rightVal = evaluate(right, thread, frameIndex, vm);
                    return evaluateComparison(leftVal, rightVal, op.trim(), vm);
                }
            }

            // Try integer literal
            try {
                long val = Long.parseLong(expression);
                return vm.mirrorOf((int) val);
            } catch (NumberFormatException e) { /* not a number */ }

            // Try string literal
            if (expression.startsWith("\"") && expression.endsWith("\"")) {
                return vm.mirrorOf(expression.substring(1, expression.length() - 1));
            }

            // Try boolean literals
            if ("true".equals(expression)) return vm.mirrorOf(true);
            if ("false".equals(expression)) return vm.mirrorOf(false);

            throw new Exception("Cannot evaluate: " + expression);
        }

        private static Value evaluateFieldAccess(String expression, StackFrame frame, ThreadReference thread, VirtualMachine vm) throws Exception {
            String[] parts = expression.split("\\.");
            Value current = null;

            // First part is a variable
            try {
                LocalVariable var = frame.visibleVariableByName(parts[0]);
                if (var != null) current = frame.getValue(var);
            } catch (AbsentInformationException e) {
                // Fall through
            }

            // If not local, try 'this' field
            if (current == null && frame.thisObject() != null) {
                ObjectReference thisObj = frame.thisObject();
                Field field = thisObj.referenceType().fieldByName(parts[0]);
                if (field != null) current = thisObj.getValue(field);
            }

            // Try static field
            if (current == null) {
                for (ReferenceType rt : vm.allClasses()) {
                    if (rt.name().equals(parts[0]) || rt.name().endsWith("." + parts[0])) {
                        if (parts.length > 1) {
                            Field field = rt.fieldByName(parts[1]);
                            if (field != null) {
                                current = rt.getValue(field);
                                // Continue with parts[2] onwards
                                for (int i = 2; i < parts.length; i++) {
                                    if (current instanceof ObjectReference) {
                                        ObjectReference obj = (ObjectReference) current;
                                        Field f = obj.referenceType().fieldByName(parts[i]);
                                        if (f != null) current = obj.getValue(f);
                                        else throw new Exception("No field: " + parts[i]);
                                    } else {
                                        throw new Exception("Not an object");
                                    }
                                }
                                return current;
                            }
                        }
                    }
                }
            }

            if (current == null) throw new Exception("Cannot resolve: " + parts[0]);

            // Navigate the rest
            for (int i = 1; i < parts.length; i++) {
                if (current instanceof ObjectReference) {
                    ObjectReference obj = (ObjectReference) current;
                    // Try "length" on arrays
                    if ("length".equals(parts[i]) && current instanceof ArrayReference) {
                        return vm.mirrorOf(((ArrayReference) current).length());
                    }
                    Field field = obj.referenceType().fieldByName(parts[i]);
                    if (field != null) {
                        current = obj.getValue(field);
                    } else {
                        throw new Exception("No field: " + parts[i]);
                    }
                } else {
                    throw new Exception("Not an object at: " + parts[i]);
                }
            }
            return current;
        }

        private static Value evaluateArrayAccess(String expression, StackFrame frame, ThreadReference thread, VirtualMachine vm) throws Exception {
            int bracket = expression.indexOf('[');
            String arrayExpr = expression.substring(0, bracket);
            String indexExpr = expression.substring(bracket + 1, expression.length() - 1);

            Value arrayVal = evaluate(arrayExpr, thread, frame.thread().frameCount() - 1 - frame.thread().frames().indexOf(frame), vm);
            if (!(arrayVal instanceof ArrayReference)) throw new Exception("Not an array");
            ArrayReference arr = (ArrayReference) arrayVal;

            Value indexVal = evaluate(indexExpr, thread, 0, vm);
            int index = toInt(indexVal);
            return arr.getValue(index);
        }

        private static Value evaluateMethodCall(String expression, StackFrame frame, ThreadReference thread, VirtualMachine vm) throws Exception {
            int paren = expression.indexOf('(');
            String methodPart = expression.substring(0, paren);
            // For now, support no-arg or toString() calls
            String argsPart = expression.substring(paren + 1, expression.length() - 1).trim();

            if (methodPart.contains(".")) {
                int dot = methodPart.lastIndexOf('.');
                String objExpr = methodPart.substring(0, dot);
                String methodName = methodPart.substring(dot + 1);
                int frameIndex = 0;
                try { frameIndex = thread.frames().indexOf(frame); } catch (Exception e) { /* default 0 */ }
                Value objVal = evaluate(objExpr, thread, frameIndex, vm);
                if (objVal instanceof ObjectReference) {
                    ObjectReference obj = (ObjectReference) objVal;
                    List<Method> methods = obj.referenceType().methodsByName(methodName);
                    if (!methods.isEmpty()) {
                        // Find best match (prefer no-arg)
                        Method method = null;
                        for (Method m : methods) {
                            if (argsPart.isEmpty() && m.argumentTypeNames().isEmpty()) { method = m; break; }
                            if (!argsPart.isEmpty() && m.argumentTypeNames().size() == 1) { method = m; break; }
                        }
                        if (method == null) method = methods.get(0);
                        List<Value> args = new ArrayList<>();
                        if (!argsPart.isEmpty()) {
                            int frameIdx = 0;
                            try { frameIdx = thread.frames().indexOf(frame); } catch (Exception e) { /* default 0 */ }
                            args.add(evaluate(argsPart, thread, frameIdx, vm));
                        }
                        return obj.invokeMethod(thread, method, args, ObjectReference.INVOKE_SINGLE_THREADED);
                    }
                }
            }
            throw new Exception("Cannot evaluate method call: " + expression);
        }

        private static Value evaluateArithmetic(Value left, Value right, char op, VirtualMachine vm) throws Exception {
            long a = toLong(left);
            long b = toLong(right);
            long result;
            switch (op) {
                case '+': result = a + b; break;
                case '-': result = a - b; break;
                case '*': result = a * b; break;
                case '/': result = a / b; break;
                case '%': result = a % b; break;
                default: throw new Exception("Unknown operator: " + op);
            }
            if (result >= Integer.MIN_VALUE && result <= Integer.MAX_VALUE) {
                return vm.mirrorOf((int) result);
            }
            return vm.mirrorOf(result);
        }

        private static Value evaluateComparison(Value left, Value right, String op, VirtualMachine vm) throws Exception {
            long a = toLong(left);
            long b = toLong(right);
            boolean result;
            switch (op) {
                case "==": result = a == b; break;
                case "!=": result = a != b; break;
                case "<": result = a < b; break;
                case ">": result = a > b; break;
                case "<=": result = a <= b; break;
                case ">=": result = a >= b; break;
                default: throw new Exception("Unknown operator: " + op);
            }
            return vm.mirrorOf(result);
        }

        static long toLong(Value val) {
            if (val instanceof IntegerValue) return ((IntegerValue) val).value();
            if (val instanceof LongValue) return ((LongValue) val).value();
            if (val instanceof ShortValue) return ((ShortValue) val).value();
            if (val instanceof ByteValue) return ((ByteValue) val).value();
            if (val instanceof CharValue) return ((CharValue) val).value();
            if (val instanceof BooleanValue) return ((BooleanValue) val).value() ? 1 : 0;
            if (val instanceof FloatValue) return (long) ((FloatValue) val).value();
            if (val instanceof DoubleValue) return (long) ((DoubleValue) val).value();
            return 0;
        }

        static int toInt(Value val) {
            return (int) toLong(val);
        }

        static String valueToString(Value val, VirtualMachine vm) {
            if (val == null) return "null";
            if (val instanceof VoidValue) return "void";
            if (val instanceof StringReference) return "\"" + ((StringReference) val).value() + "\"";
            if (val instanceof IntegerValue) return String.valueOf(((IntegerValue) val).value());
            if (val instanceof LongValue) return String.valueOf(((LongValue) val).value());
            if (val instanceof ShortValue) return String.valueOf(((ShortValue) val).value());
            if (val instanceof ByteValue) return String.valueOf(((ByteValue) val).value());
            if (val instanceof CharValue) return "'" + ((CharValue) val).value() + "'";
            if (val instanceof BooleanValue) return String.valueOf(((BooleanValue) val).value());
            if (val instanceof FloatValue) return String.valueOf(((FloatValue) val).value());
            if (val instanceof DoubleValue) return String.valueOf(((DoubleValue) val).value());
            if (val instanceof ArrayReference) {
                ArrayReference arr = (ArrayReference) val;
                return arr.type().name() + "[" + arr.length() + "]";
            }
            if (val instanceof ObjectReference) {
                ObjectReference obj = (ObjectReference) val;
                return obj.referenceType().name() + "@" + obj.uniqueID();
            }
            return val.toString();
        }

        static String valueType(Value val) {
            if (val == null) return "null";
            if (val instanceof StringReference) return "String";
            if (val instanceof IntegerValue) return "int";
            if (val instanceof LongValue) return "long";
            if (val instanceof ShortValue) return "short";
            if (val instanceof ByteValue) return "byte";
            if (val instanceof CharValue) return "char";
            if (val instanceof BooleanValue) return "boolean";
            if (val instanceof FloatValue) return "float";
            if (val instanceof DoubleValue) return "double";
            if (val instanceof ArrayReference) return ((ArrayReference) val).type().name();
            if (val instanceof ObjectReference) return ((ObjectReference) val).referenceType().name();
            return "unknown";
        }

        static int variablesReference(Value val, VariableRefPool pool, ThreadReference thread, int frameIndex) {
            if (val instanceof ArrayReference || (val instanceof ObjectReference && !(val instanceof StringReference))) {
                return pool.allocRef(val, null, thread, frameIndex);
            }
            return 0;
        }
    }

    // ── DapDispatcher ───────────────────────────────────────────────────

    static class DapDispatcher {
        private final DapTransport transport;
        private JdiEngine engine;
        private boolean configurationDone = false;

        DapDispatcher(DapTransport transport) {
            this.transport = transport;
        }

        void shutdown() {
            if (engine != null) engine.shutdown();
        }

        @SuppressWarnings("unchecked")
        void dispatch(Map<String, Object> request) {
            String command = Json.getString(request, "command");
            int seq = Json.getInt(request, "seq", 0);
            Map<String, Object> args = Json.getObject(request, "arguments");
            if (args == null) args = new HashMap<>();

            try {
                switch (command) {
                    case "initialize": handleInitialize(seq, args); break;
                    case "launch": handleLaunch(seq, args); break;
                    case "configurationDone": handleConfigurationDone(seq, args); break;
                    case "setBreakpoints": handleSetBreakpoints(seq, args); break;
                    case "setFunctionBreakpoints": handleSetFunctionBreakpoints(seq, args); break;
                    case "setExceptionBreakpoints": handleSetExceptionBreakpoints(seq, args); break;
                    case "continue": handleContinue(seq, args); break;
                    case "next": handleNext(seq, args); break;
                    case "stepIn": handleStepIn(seq, args); break;
                    case "stepOut": handleStepOut(seq, args); break;
                    case "pause": handlePause(seq, args); break;
                    case "threads": handleThreads(seq, args); break;
                    case "stackTrace": handleStackTrace(seq, args); break;
                    case "scopes": handleScopes(seq, args); break;
                    case "variables": handleVariables(seq, args); break;
                    case "evaluate": handleEvaluate(seq, args); break;
                    case "setVariable": handleSetVariable(seq, args); break;
                    case "setExpression": handleSetExpression(seq, args); break;
                    case "completions": handleCompletions(seq, args); break;
                    case "disconnect": handleDisconnect(seq, args); break;
                    case "terminate": handleTerminate(seq, args); break;
                    case "restart": handleRestart(seq, args); break;
                    case "restartFrame": handleRestartFrame(seq, args); break;
                    case "stepInTargets": handleStepInTargets(seq, args); break;
                    case "breakpointLocations": handleBreakpointLocations(seq, args); break;
                    case "exceptionInfo": handleExceptionInfo(seq, args); break;
                    case "modules": handleModules(seq, args); break;
                    case "loadedSources": handleLoadedSources(seq, args); break;
                    case "source": handleSource(seq, args); break;
                    case "terminateThreads": handleTerminateThreads(seq, args); break;
                    case "cancel": handleCancel(seq, args); break;
                    default:
                        transport.sendErrorResponse(seq, command, "Unknown command: " + command);
                }
            } catch (Exception e) {
                transport.sendErrorResponse(seq, command, e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName());
            }
        }

        // ── Initialize ──

        private void handleInitialize(int seq, Map<String, Object> args) {
            Map<String, Object> capabilities = new LinkedHashMap<>();
            capabilities.put("supportsConfigurationDoneRequest", true);
            capabilities.put("supportsConditionalBreakpoints", true);
            capabilities.put("supportsHitConditionalBreakpoints", true);
            capabilities.put("supportsLogPoints", true);
            capabilities.put("supportsFunctionBreakpoints", true);
            capabilities.put("supportsSetVariable", true);
            capabilities.put("supportsSetExpression", true);
            capabilities.put("supportsCompletionsRequest", true);
            capabilities.put("supportsRestartRequest", true);
            capabilities.put("supportsRestartFrame", true);
            capabilities.put("supportsStepInTargetsRequest", true);
            capabilities.put("supportsBreakpointLocationsRequest", true);
            capabilities.put("supportsExceptionInfoRequest", true);
            capabilities.put("supportsTerminateRequest", true);
            capabilities.put("supportTerminateDebuggee", true);
            capabilities.put("supportsModulesRequest", true);
            capabilities.put("supportsLoadedSourcesRequest", true);
            capabilities.put("supportsSteppingGranularity", true);
            capabilities.put("supportsCancelRequest", true);
            capabilities.put("supportsTerminateThreadsRequest", true);
            capabilities.put("supportsGotoTargetsRequest", false);
            capabilities.put("supportsDataBreakpoints", false);
            capabilities.put("supportsReadMemoryRequest", false);
            capabilities.put("supportsWriteMemoryRequest", false);
            capabilities.put("supportsDisassembleRequest", false);
            capabilities.put("supportsInstructionBreakpoints", false);
            capabilities.put("supportsStepBack", false);
            capabilities.put("supportsValueFormattingOptions", true);

            // Exception breakpoint filters
            List<Map<String, Object>> filters = new ArrayList<>();
            Map<String, Object> caught = new LinkedHashMap<>();
            caught.put("filter", "caught");
            caught.put("label", "Caught Exceptions");
            caught.put("default", false);
            filters.add(caught);
            Map<String, Object> uncaught = new LinkedHashMap<>();
            uncaught.put("filter", "uncaught");
            uncaught.put("label", "Uncaught Exceptions");
            uncaught.put("default", false);
            filters.add(uncaught);
            capabilities.put("exceptionBreakpointFilters", filters);

            transport.sendResponse(seq, "initialize", true, capabilities);
        }

        // ── Launch ──

        private void handleLaunch(int seq, Map<String, Object> args) throws Exception {
            String program = Json.getString(args, "program");
            boolean stopOnEntry = Json.getBool(args, "stopOnEntry", false);
            List<Object> launchArgs = Json.getArray(args, "args");

            if (program == null) {
                transport.sendErrorResponse(seq, "launch", "program is required");
                return;
            }

            // Build class name and classpath from the program path
            String className;
            String classPath;
            Path sourcePath = Paths.get(program);

            // Check if .class file exists next to .java, compile if needed
            String baseName = sourcePath.getFileName().toString();
            if (baseName.endsWith(".java")) {
                // Scan for package declaration
                String packageName = scanPackage(sourcePath);
                String simpleClassName = baseName.substring(0, baseName.length() - 5);
                className = packageName.isEmpty() ? simpleClassName : packageName + "." + simpleClassName;
                classPath = sourcePath.getParent().toString();

                // Check if .class file exists
                Path classFile = sourcePath.getParent().resolve(simpleClassName + ".class");
                if (!Files.exists(classFile)) {
                    // Compile
                    ProcessBuilder pb = new ProcessBuilder("javac", "-g", "-d", classPath, program);
                    pb.redirectErrorStream(true);
                    Process proc = pb.start();
                    int exitCode = proc.waitFor();
                    if (exitCode != 0) {
                        byte[] output = proc.getInputStream().readAllBytes();
                        transport.sendErrorResponse(seq, "launch", "Compilation failed: " + new String(output));
                        return;
                    }
                }
            } else {
                transport.sendErrorResponse(seq, "launch", "Only .java files are supported");
                return;
            }

            // Build program arguments
            List<String> progArgs = new ArrayList<>();
            if (launchArgs != null) {
                for (Object a : launchArgs) {
                    if (a instanceof String) progArgs.add((String) a);
                    else if (a != null) progArgs.add(a.toString());
                }
            }

            engine = new JdiEngine(transport);
            engine.launch(className, classPath, progArgs, stopOnEntry, program);

            transport.sendResponse(seq, "launch", true, null);
            transport.sendEvent("initialized", null);
        }

        private String scanPackage(Path sourcePath) {
            try {
                List<String> lines = Files.readAllLines(sourcePath);
                for (String line : lines) {
                    line = line.trim();
                    if (line.startsWith("package ")) {
                        int semi = line.indexOf(';');
                        if (semi > 0) return line.substring(8, semi).trim();
                    }
                    // Stop scanning after class/interface/enum declaration
                    if (line.startsWith("public ") || line.startsWith("class ") ||
                        line.startsWith("interface ") || line.startsWith("enum ")) break;
                }
            } catch (IOException e) {
                // Default to no package
            }
            return "";
        }

        // ── Configuration Done ──

        private void handleConfigurationDone(int seq, Map<String, Object> args) {
            configurationDone = true;
            if (engine != null) {
                engine.configurationDone();
            }
            transport.sendResponse(seq, "configurationDone", true, null);
        }

        // ── Breakpoints ──

        @SuppressWarnings("unchecked")
        private void handleSetBreakpoints(int seq, Map<String, Object> args) {
            Map<String, Object> source = Json.getObject(args, "source");
            String path = source != null ? Json.getString(source, "path") : null;
            if (path == null) {
                transport.sendErrorResponse(seq, "setBreakpoints", "source.path is required");
                return;
            }

            List<Object> bps = Json.getArray(args, "breakpoints");
            List<Map<String, Object>> bpSpecs = new ArrayList<>();
            if (bps != null) {
                for (Object bp : bps) {
                    if (bp instanceof Map) bpSpecs.add((Map<String, Object>) bp);
                }
            }

            List<Map<String, Object>> results = engine.breakpointManager.setBreakpoints(path, bpSpecs);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("breakpoints", results);
            transport.sendResponse(seq, "setBreakpoints", true, body);
        }

        @SuppressWarnings("unchecked")
        private void handleSetFunctionBreakpoints(int seq, Map<String, Object> args) {
            List<Object> bps = Json.getArray(args, "breakpoints");
            List<Map<String, Object>> specs = new ArrayList<>();
            if (bps != null) {
                for (Object bp : bps) {
                    if (bp instanceof Map) specs.add((Map<String, Object>) bp);
                }
            }
            List<Map<String, Object>> results = engine.breakpointManager.setFunctionBreakpoints(specs);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("breakpoints", results);
            transport.sendResponse(seq, "setFunctionBreakpoints", true, body);
        }

        @SuppressWarnings("unchecked")
        private void handleSetExceptionBreakpoints(int seq, Map<String, Object> args) {
            List<Object> filterList = Json.getArray(args, "filters");
            List<String> filters = new ArrayList<>();
            if (filterList != null) {
                for (Object f : filterList) {
                    if (f instanceof String) filters.add((String) f);
                }
            }
            engine.breakpointManager.setExceptionBreakpoints(filters);
            transport.sendResponse(seq, "setExceptionBreakpoints", true, null);
        }

        // ── Execution Control ──

        private void handleContinue(int seq, Map<String, Object> args) {
            engine.resume();
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("allThreadsContinued", true);
            transport.sendResponse(seq, "continue", true, body);
            engine.waitForStopAndNotify();
        }

        private void handleNext(int seq, Map<String, Object> args) {
            int threadId = Json.getInt(args, "threadId", 1);
            engine.stepOver(threadId);
            transport.sendResponse(seq, "next", true, null);
            engine.waitForStopAndNotify();
        }

        private void handleStepIn(int seq, Map<String, Object> args) {
            int threadId = Json.getInt(args, "threadId", 1);
            engine.stepInto(threadId);
            transport.sendResponse(seq, "stepIn", true, null);
            engine.waitForStopAndNotify();
        }

        private void handleStepOut(int seq, Map<String, Object> args) {
            int threadId = Json.getInt(args, "threadId", 1);
            engine.stepOut(threadId);
            transport.sendResponse(seq, "stepOut", true, null);
            engine.waitForStopAndNotify();
        }

        private void handlePause(int seq, Map<String, Object> args) {
            if (engine != null && engine.vm != null) {
                engine.vm.suspend();
                Map<String, Object> body = new LinkedHashMap<>();
                body.put("reason", "pause");
                body.put("threadId", 1);
                body.put("allThreadsStopped", true);
                transport.sendEvent("stopped", body);
            }
            transport.sendResponse(seq, "pause", true, null);
        }

        // ── Threads ──

        private void handleThreads(int seq, Map<String, Object> args) {
            List<Map<String, Object>> threads = new ArrayList<>();
            if (engine != null && engine.vm != null) {
                try {
                    for (ThreadReference t : engine.vm.allThreads()) {
                        Map<String, Object> thread = new LinkedHashMap<>();
                        thread.put("id", (int) t.uniqueID());
                        thread.put("name", t.name());
                        threads.add(thread);
                    }
                } catch (VMDisconnectedException e) {
                    // VM gone
                }
            }
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("threads", threads);
            transport.sendResponse(seq, "threads", true, body);
        }

        // ── Stack Trace ──

        private void handleStackTrace(int seq, Map<String, Object> args) {
            int threadId = Json.getInt(args, "threadId", 1);
            int startFrame = Json.getInt(args, "startFrame", 0);
            int levels = Json.getInt(args, "levels", 0);

            List<Map<String, Object>> frames = new ArrayList<>();
            int totalFrames = 0;

            if (engine != null && engine.vm != null) {
                try {
                    ThreadReference thread = findThread(threadId);
                    if (thread != null) {
                        List<StackFrame> allFrames = thread.frames();
                        totalFrames = allFrames.size();
                        int end = levels > 0 ? Math.min(startFrame + levels, totalFrames) : totalFrames;
                        for (int i = startFrame; i < end; i++) {
                            StackFrame sf = allFrames.get(i);
                            Location loc = sf.location();
                            Map<String, Object> frame = new LinkedHashMap<>();
                            frame.put("id", i);
                            frame.put("name", loc.method().declaringType().name() + "." + loc.method().name());
                            try {
                                Map<String, Object> source = new LinkedHashMap<>();
                                source.put("name", loc.sourceName());
                                if (engine.sourcePath != null) {
                                    source.put("path", engine.sourcePath);
                                }
                                frame.put("source", source);
                            } catch (AbsentInformationException e) {
                                // No source info
                            }
                            frame.put("line", loc.lineNumber());
                            frame.put("column", 0);
                            frames.add(frame);
                        }
                    }
                } catch (IncompatibleThreadStateException | VMDisconnectedException e) {
                    // Thread not suspended or VM gone
                }
            }

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("stackFrames", frames);
            body.put("totalFrames", totalFrames);
            transport.sendResponse(seq, "stackTrace", true, body);
        }

        // ── Scopes ──

        private void handleScopes(int seq, Map<String, Object> args) {
            int frameId = Json.getInt(args, "frameId", 0);
            List<Map<String, Object>> scopes = new ArrayList<>();

            if (engine != null && engine.vm != null) {
                ThreadReference thread = engine.getStoppedThread();
                if (thread != null) {
                    int localsRef = engine.varPool.allocRef("locals", "locals", thread, frameId);
                    Map<String, Object> locals = new LinkedHashMap<>();
                    locals.put("name", "Locals");
                    locals.put("presentationHint", "locals");
                    locals.put("variablesReference", localsRef);
                    locals.put("expensive", false);
                    scopes.add(locals);

                    int argsRef = engine.varPool.allocRef("arguments", "arguments", thread, frameId);
                    Map<String, Object> arguments = new LinkedHashMap<>();
                    arguments.put("name", "Arguments");
                    arguments.put("presentationHint", "arguments");
                    arguments.put("variablesReference", argsRef);
                    arguments.put("expensive", false);
                    scopes.add(arguments);
                }
            }

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("scopes", scopes);
            transport.sendResponse(seq, "scopes", true, body);
        }

        // ── Variables ──

        private void handleVariables(int seq, Map<String, Object> args) {
            int variablesReference = Json.getInt(args, "variablesReference", 0);
            List<Map<String, Object>> variables = new ArrayList<>();

            VariableRefPool.PoolEntry entry = engine.varPool.getEntry(variablesReference);
            if (entry != null && engine.vm != null) {
                try {
                    if ("locals".equals(entry.scope)) {
                        ThreadReference thread = entry.thread;
                        StackFrame frame = thread.frame(entry.frameIndex);
                        try {
                            List<LocalVariable> vars = frame.visibleVariables();
                            for (LocalVariable v : vars) {
                                Value val = frame.getValue(v);
                                Map<String, Object> var = new LinkedHashMap<>();
                                var.put("name", v.name());
                                var.put("value", ExpressionEvaluator.valueToString(val, engine.vm));
                                var.put("type", ExpressionEvaluator.valueType(val));
                                var.put("variablesReference", ExpressionEvaluator.variablesReference(val, engine.varPool, thread, entry.frameIndex));
                                variables.add(var);
                            }
                        } catch (AbsentInformationException e) {
                            // No debug info
                        }
                    } else if ("arguments".equals(entry.scope)) {
                        ThreadReference thread = entry.thread;
                        StackFrame frame = thread.frame(entry.frameIndex);
                        try {
                            List<LocalVariable> vars = frame.visibleVariables();
                            Method method = frame.location().method();
                            List<String> argNames = method.argumentTypeNames();
                            int argCount = argNames.size();
                            // JDI includes arguments in visibleVariables, they come first
                            for (int i = 0; i < Math.min(argCount, vars.size()); i++) {
                                LocalVariable v = vars.get(i);
                                if (v.isArgument()) {
                                    Value val = frame.getValue(v);
                                    Map<String, Object> var = new LinkedHashMap<>();
                                    var.put("name", v.name());
                                    var.put("value", ExpressionEvaluator.valueToString(val, engine.vm));
                                    var.put("type", ExpressionEvaluator.valueType(val));
                                    var.put("variablesReference", ExpressionEvaluator.variablesReference(val, engine.varPool, thread, entry.frameIndex));
                                    variables.add(var);
                                }
                            }
                        } catch (AbsentInformationException e) {
                            // No debug info
                        }
                    } else if (entry.jdiValue instanceof ArrayReference) {
                        ArrayReference arr = (ArrayReference) entry.jdiValue;
                        int len = arr.length();
                        for (int i = 0; i < len && i < 100; i++) {
                            Value val = arr.getValue(i);
                            Map<String, Object> var = new LinkedHashMap<>();
                            var.put("name", "[" + i + "]");
                            var.put("value", ExpressionEvaluator.valueToString(val, engine.vm));
                            var.put("type", ExpressionEvaluator.valueType(val));
                            var.put("variablesReference", ExpressionEvaluator.variablesReference(val, engine.varPool, entry.thread, entry.frameIndex));
                            variables.add(var);
                        }
                    } else if (entry.jdiValue instanceof ObjectReference) {
                        ObjectReference obj = (ObjectReference) entry.jdiValue;
                        ReferenceType refType = obj.referenceType();
                        for (Field field : refType.allFields()) {
                            Value val = obj.getValue(field);
                            Map<String, Object> var = new LinkedHashMap<>();
                            var.put("name", field.name());
                            var.put("value", ExpressionEvaluator.valueToString(val, engine.vm));
                            var.put("type", ExpressionEvaluator.valueType(val));
                            var.put("variablesReference", ExpressionEvaluator.variablesReference(val, engine.varPool, entry.thread, entry.frameIndex));
                            variables.add(var);
                        }
                    }
                } catch (IncompatibleThreadStateException | VMDisconnectedException | InvalidStackFrameException e) {
                    // Thread not suspended or VM gone
                }
            }

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("variables", variables);
            transport.sendResponse(seq, "variables", true, body);
        }

        // ── Evaluate ──

        private void handleEvaluate(int seq, Map<String, Object> args) {
            String expression = Json.getString(args, "expression");
            int frameId = Json.getInt(args, "frameId", 0);

            if (expression == null || expression.isEmpty()) {
                transport.sendErrorResponse(seq, "evaluate", "expression is required");
                return;
            }

            try {
                ThreadReference thread = engine.getStoppedThread();
                if (thread == null) {
                    transport.sendErrorResponse(seq, "evaluate", "No stopped thread");
                    return;
                }

                Value val = ExpressionEvaluator.evaluate(expression, thread, frameId, engine.vm);
                Map<String, Object> body = new LinkedHashMap<>();
                body.put("result", ExpressionEvaluator.valueToString(val, engine.vm));
                body.put("type", ExpressionEvaluator.valueType(val));
                body.put("variablesReference", ExpressionEvaluator.variablesReference(val, engine.varPool, thread, frameId));
                transport.sendResponse(seq, "evaluate", true, body);
            } catch (Exception e) {
                transport.sendErrorResponse(seq, "evaluate", "Evaluation failed: " + (e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()));
            }
        }

        // ── Set Variable ──

        private void handleSetVariable(int seq, Map<String, Object> args) {
            int variablesReference = Json.getInt(args, "variablesReference", 0);
            String name = Json.getString(args, "name");
            String value = Json.getString(args, "value");

            try {
                ThreadReference thread = engine.getStoppedThread();
                if (thread == null) {
                    transport.sendErrorResponse(seq, "setVariable", "No stopped thread");
                    return;
                }

                // Find the frame from the variablesReference
                VariableRefPool.PoolEntry entry = engine.varPool.getEntry(variablesReference);
                int frameIndex = entry != null ? entry.frameIndex : 0;
                StackFrame frame = thread.frame(frameIndex);

                LocalVariable var = frame.visibleVariableByName(name);
                if (var == null) {
                    transport.sendErrorResponse(seq, "setVariable", "Variable not found: " + name);
                    return;
                }

                Value newVal = parseValue(value, var.type(), engine.vm);
                frame.setValue(var, newVal);

                Map<String, Object> body = new LinkedHashMap<>();
                body.put("value", ExpressionEvaluator.valueToString(newVal, engine.vm));
                body.put("type", ExpressionEvaluator.valueType(newVal));
                body.put("variablesReference", ExpressionEvaluator.variablesReference(newVal, engine.varPool, thread, frameIndex));
                transport.sendResponse(seq, "setVariable", true, body);
            } catch (Exception e) {
                transport.sendErrorResponse(seq, "setVariable", "Failed: " + (e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()));
            }
        }

        // ── Set Expression ──

        private void handleSetExpression(int seq, Map<String, Object> args) {
            String expression = Json.getString(args, "expression");
            String value = Json.getString(args, "value");
            int frameId = Json.getInt(args, "frameId", 0);

            try {
                ThreadReference thread = engine.getStoppedThread();
                if (thread == null) {
                    transport.sendErrorResponse(seq, "setExpression", "No stopped thread");
                    return;
                }

                StackFrame frame = thread.frame(frameId);
                LocalVariable var = frame.visibleVariableByName(expression);
                if (var == null) {
                    transport.sendErrorResponse(seq, "setExpression", "Variable not found: " + expression);
                    return;
                }

                Value newVal = parseValue(value, var.type(), engine.vm);
                frame.setValue(var, newVal);

                Map<String, Object> body = new LinkedHashMap<>();
                body.put("value", ExpressionEvaluator.valueToString(newVal, engine.vm));
                body.put("type", ExpressionEvaluator.valueType(newVal));
                body.put("variablesReference", ExpressionEvaluator.variablesReference(newVal, engine.varPool, thread, frameId));
                transport.sendResponse(seq, "setExpression", true, body);
            } catch (Exception e) {
                transport.sendErrorResponse(seq, "setExpression", "Failed: " + (e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()));
            }
        }

        private Value parseValue(String value, Type type, VirtualMachine vm) {
            String typeName = type.name();
            value = value.trim();
            switch (typeName) {
                case "int": return vm.mirrorOf(Integer.parseInt(value));
                case "long": return vm.mirrorOf(Long.parseLong(value));
                case "short": return vm.mirrorOf(Short.parseShort(value));
                case "byte": return vm.mirrorOf(Byte.parseByte(value));
                case "char": return vm.mirrorOf(value.charAt(0));
                case "boolean": return vm.mirrorOf(Boolean.parseBoolean(value));
                case "float": return vm.mirrorOf(Float.parseFloat(value));
                case "double": return vm.mirrorOf(Double.parseDouble(value));
                case "java.lang.String":
                    if (value.startsWith("\"") && value.endsWith("\""))
                        value = value.substring(1, value.length() - 1);
                    return vm.mirrorOf(value);
                default:
                    // Try int as fallback
                    try { return vm.mirrorOf(Integer.parseInt(value)); }
                    catch (NumberFormatException e) { return vm.mirrorOf(value); }
            }
        }

        // ── Completions ──

        private void handleCompletions(int seq, Map<String, Object> args) {
            String text = Json.getString(args, "text");
            int column = Json.getInt(args, "column", 0);
            List<Map<String, Object>> targets = new ArrayList<>();

            if (engine != null && engine.vm != null) {
                ThreadReference thread = engine.getStoppedThread();
                if (thread != null) {
                    try {
                        StackFrame frame = thread.frame(0);
                        String prefix = text != null ? text.substring(0, Math.min(column, text.length())) : "";
                        try {
                            for (LocalVariable v : frame.visibleVariables()) {
                                if (v.name().startsWith(prefix)) {
                                    Map<String, Object> target = new LinkedHashMap<>();
                                    target.put("label", v.name());
                                    target.put("type", "variable");
                                    targets.add(target);
                                }
                            }
                        } catch (AbsentInformationException e) {
                            // No debug info
                        }
                    } catch (IncompatibleThreadStateException e) {
                        // Thread not suspended
                    }
                }
            }

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("targets", targets);
            transport.sendResponse(seq, "completions", true, body);
        }

        // ── Disconnect ──

        private void handleDisconnect(int seq, Map<String, Object> args) {
            boolean terminateDebuggee = Json.getBool(args, "terminateDebuggee", true);
            if (engine != null) {
                engine.disconnect(terminateDebuggee);
            }
            transport.sendResponse(seq, "disconnect", true, null);
        }

        // ── Terminate ──

        private void handleTerminate(int seq, Map<String, Object> args) {
            if (engine != null) {
                engine.disconnect(true);
            }
            transport.sendResponse(seq, "terminate", true, null);
            transport.sendEvent("terminated", null);
        }

        // ── Restart ──

        private void handleRestart(int seq, Map<String, Object> args) {
            if (engine == null) {
                transport.sendErrorResponse(seq, "restart", "No active session");
                return;
            }

            try {
                configurationDone = false;
                engine.restart();
                transport.sendResponse(seq, "restart", true, null);
                transport.sendEvent("initialized", null);
            } catch (Exception e) {
                transport.sendErrorResponse(seq, "restart", "Restart failed: " + (e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()));
            }
        }

        // ── Restart Frame ──

        private void handleRestartFrame(int seq, Map<String, Object> args) {
            int frameId = Json.getInt(args, "frameId", 0);
            try {
                ThreadReference thread = engine.getStoppedThread();
                if (thread == null) {
                    transport.sendErrorResponse(seq, "restartFrame", "No stopped thread");
                    return;
                }
                List<StackFrame> frames = thread.frames();
                if (frameId < 0 || frameId >= frames.size()) {
                    transport.sendErrorResponse(seq, "restartFrame", "Invalid frame ID");
                    return;
                }
                // Pop frames up to and including the target frame
                thread.popFrames(frames.get(frameId));
                engine.varPool.clear();
                transport.sendResponse(seq, "restartFrame", true, null);

                // Send stopped event to indicate we're back at the frame
                Map<String, Object> body = new LinkedHashMap<>();
                body.put("reason", "restart");
                body.put("threadId", (int) thread.uniqueID());
                body.put("allThreadsStopped", true);
                transport.sendEvent("stopped", body);
            } catch (IncompatibleThreadStateException e) {
                transport.sendErrorResponse(seq, "restartFrame", "Thread not suspended");
            } catch (Exception e) {
                transport.sendErrorResponse(seq, "restartFrame", "Failed: " + (e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()));
            }
        }

        // ── Step In Targets ──

        private void handleStepInTargets(int seq, Map<String, Object> args) {
            int frameId = Json.getInt(args, "frameId", 0);
            List<Map<String, Object>> targets = new ArrayList<>();

            try {
                ThreadReference thread = engine.getStoppedThread();
                if (thread != null) {
                    StackFrame frame = thread.frame(frameId);
                    Location loc = frame.location();
                    Method currentMethod = loc.method();
                    int currentLine = loc.lineNumber();

                    // Find methods called on this line by looking at bytecode locations
                    ReferenceType refType = currentMethod.declaringType();
                    try {
                        List<Location> locs = refType.locationsOfLine(currentLine);
                        Set<String> seen = new HashSet<>();
                        int targetId = 0;

                        // Look at all methods in the class and find calls from this location
                        // Since JDI doesn't directly expose call targets, we look at
                        // what methods exist that could be called from this line
                        for (Location l : locs) {
                            // The locations on this line may reference different methods
                            String methodKey = l.method().name();
                            if (!seen.contains(methodKey) && !l.method().equals(currentMethod)) {
                                Map<String, Object> target = new LinkedHashMap<>();
                                target.put("id", targetId++);
                                target.put("label", l.method().declaringType().name() + "." + l.method().name());
                                targets.add(target);
                                seen.add(methodKey);
                            }
                        }

                        // If we found no targets from locations, try analyzing the source line
                        if (targets.isEmpty()) {
                            // Simple heuristic: look for method names in all loaded classes
                            // that could be invoked from this line
                            try {
                                String sourceLine = getSourceLine(engine.sourcePath, currentLine);
                                if (sourceLine != null) {
                                    for (ReferenceType rt : engine.vm.allClasses()) {
                                        for (Method m : rt.methods()) {
                                            if (!m.isAbstract() && !m.isNative() &&
                                                sourceLine.contains(m.name() + "(")) {
                                                String key = m.declaringType().name() + "." + m.name();
                                                if (!seen.contains(key)) {
                                                    Map<String, Object> target = new LinkedHashMap<>();
                                                    target.put("id", targetId++);
                                                    target.put("label", key);
                                                    targets.add(target);
                                                    seen.add(key);
                                                }
                                            }
                                        }
                                    }
                                }
                            } catch (Exception e) {
                                // Fall through
                            }
                        }
                    } catch (AbsentInformationException e) {
                        // No source info
                    }
                }
            } catch (IncompatibleThreadStateException | VMDisconnectedException e) {
                // Thread not suspended or VM gone
            }

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("targets", targets);
            transport.sendResponse(seq, "stepInTargets", true, body);
        }

        private String getSourceLine(String sourcePath, int lineNumber) {
            if (sourcePath == null) return null;
            try {
                List<String> lines = Files.readAllLines(Paths.get(sourcePath));
                if (lineNumber > 0 && lineNumber <= lines.size()) {
                    return lines.get(lineNumber - 1);
                }
            } catch (IOException e) {
                // ignore
            }
            return null;
        }

        // ── Breakpoint Locations ──

        private void handleBreakpointLocations(int seq, Map<String, Object> args) {
            Map<String, Object> source = Json.getObject(args, "source");
            String path = source != null ? Json.getString(source, "path") : null;
            int line = Json.getInt(args, "line", 0);
            int endLine = Json.getInt(args, "endLine", line);

            List<Map<String, Object>> locations = new ArrayList<>();
            if (path != null && engine != null) {
                locations = engine.breakpointManager.getBreakpointLocations(path, line, endLine);
            }

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("breakpoints", locations);
            transport.sendResponse(seq, "breakpointLocations", true, body);
        }

        // ── Exception Info ──

        private void handleExceptionInfo(int seq, Map<String, Object> args) {
            if (engine == null || engine.lastException == null) {
                transport.sendErrorResponse(seq, "exceptionInfo", "No exception information available");
                return;
            }

            ObjectReference exc = engine.lastException;
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("exceptionId", exc.referenceType().name());
            body.put("breakMode", engine.lastExceptionCaught ? "always" : "unhandled");

            // Try to get exception message
            try {
                ThreadReference thread = engine.getStoppedThread();
                if (thread != null) {
                    List<Method> methods = exc.referenceType().methodsByName("getMessage");
                    if (!methods.isEmpty()) {
                        Value msgVal = exc.invokeMethod(thread, methods.get(0), Collections.emptyList(), ObjectReference.INVOKE_SINGLE_THREADED);
                        if (msgVal instanceof StringReference) {
                            body.put("description", ((StringReference) msgVal).value());
                        }
                    }
                }
            } catch (Exception e) {
                // Can't get message, that's ok
            }

            // Add exception details
            Map<String, Object> details = new LinkedHashMap<>();
            details.put("typeName", exc.referenceType().name());
            body.put("details", details);

            transport.sendResponse(seq, "exceptionInfo", true, body);
        }

        // ── Modules ──

        private void handleModules(int seq, Map<String, Object> args) {
            List<Map<String, Object>> modules = new ArrayList<>();
            if (engine != null && engine.vm != null) {
                int id = 0;
                Set<String> seen = new HashSet<>();
                for (ReferenceType refType : engine.vm.allClasses()) {
                    String name = refType.name();
                    if (seen.contains(name)) continue;
                    // Filter to user classes (skip JDK internal classes for brevity)
                    if (name.startsWith("java.") || name.startsWith("javax.") ||
                        name.startsWith("jdk.") || name.startsWith("sun.") ||
                        name.startsWith("com.sun.")) continue;
                    seen.add(name);
                    Map<String, Object> module = new LinkedHashMap<>();
                    module.put("id", id++);
                    module.put("name", name);
                    try {
                        module.put("path", refType.sourceName());
                    } catch (AbsentInformationException e) {
                        module.put("path", "");
                    }
                    modules.add(module);
                }
            }
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("modules", modules);
            body.put("totalModules", modules.size());
            transport.sendResponse(seq, "modules", true, body);
        }

        // ── Loaded Sources ──

        private void handleLoadedSources(int seq, Map<String, Object> args) {
            List<Map<String, Object>> sources = new ArrayList<>();
            if (engine != null && engine.vm != null) {
                Set<String> seen = new HashSet<>();
                for (ReferenceType refType : engine.vm.allClasses()) {
                    try {
                        String srcName = refType.sourceName();
                        if (seen.contains(srcName)) continue;
                        seen.add(srcName);
                        Map<String, Object> source = new LinkedHashMap<>();
                        source.put("name", srcName);
                        if (engine.sourcePath != null && srcName.equals(Paths.get(engine.sourcePath).getFileName().toString())) {
                            source.put("path", engine.sourcePath);
                        }
                        sources.add(source);
                    } catch (AbsentInformationException e) {
                        // Skip
                    }
                }
            }
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("sources", sources);
            transport.sendResponse(seq, "loadedSources", true, body);
        }

        // ── Source ──

        private void handleSource(int seq, Map<String, Object> args) {
            Map<String, Object> source = Json.getObject(args, "source");
            String path = source != null ? Json.getString(source, "path") : null;
            int sourceReference = Json.getInt(args, "sourceReference", 0);

            if (path != null) {
                try {
                    String content = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
                    Map<String, Object> body = new LinkedHashMap<>();
                    body.put("content", content);
                    transport.sendResponse(seq, "source", true, body);
                    return;
                } catch (IOException e) {
                    // Fall through
                }
            }
            transport.sendErrorResponse(seq, "source", "Source not available");
        }

        // ── Terminate Threads ──

        private void handleTerminateThreads(int seq, Map<String, Object> args) {
            // JVM doesn't support arbitrary thread termination, but we acknowledge
            transport.sendResponse(seq, "terminateThreads", true, null);
        }

        // ── Cancel ──

        private void handleCancel(int seq, Map<String, Object> args) {
            transport.sendResponse(seq, "cancel", true, null);
        }

        private ThreadReference findThread(int threadId) {
            if (engine == null || engine.vm == null) return null;
            try {
                for (ThreadReference t : engine.vm.allThreads()) {
                    if (t.uniqueID() == threadId) return t;
                }
            } catch (VMDisconnectedException e) {
                // VM gone
            }
            return null;
        }
    }

    // ── JdiEngine ───────────────────────────────────────────────────────

    static class JdiEngine {
        private final DapTransport transport;
        VirtualMachine vm;
        final BreakpointManager breakpointManager = new BreakpointManager();
        final VariableRefPool varPool = new VariableRefPool();
        private JdiEventThread eventThread;
        private volatile ThreadReference stoppedThread;
        private boolean stopOnEntry;
        String sourcePath; // Original source file path
        ObjectReference lastException;
        boolean lastExceptionCaught;

        // Saved launch parameters for restart
        private String savedClassName;
        private String savedClassPath;
        private List<String> savedArgs;
        private boolean savedStopOnEntry;
        private String savedProgram;

        // Output capture threads
        private Thread stdoutThread;
        private Thread stderrThread;

        JdiEngine(DapTransport transport) {
            this.transport = transport;
        }

        void launch(String className, String classPath, List<String> args, boolean stopOnEntry, String program) throws Exception {
            this.stopOnEntry = stopOnEntry;
            this.sourcePath = program;
            this.savedClassName = className;
            this.savedClassPath = classPath;
            this.savedArgs = new ArrayList<>(args);
            this.savedStopOnEntry = stopOnEntry;
            this.savedProgram = program;

            LaunchingConnector connector = Bootstrap.virtualMachineManager().defaultConnector();
            Map<String, Connector.Argument> connArgs = connector.defaultArguments();

            // Build main argument: className + args
            StringBuilder mainArg = new StringBuilder(className);
            for (String arg : args) {
                mainArg.append(" ").append(arg);
            }
            connArgs.get("main").setValue(mainArg.toString());

            // Set classpath
            Connector.Argument options = connArgs.get("options");
            if (options != null) {
                options.setValue("-cp " + classPath);
            }

            vm = connector.launch(connArgs);
            breakpointManager.setVm(vm);
            breakpointManager.setupClassPrepareRequests();

            // Start JDI event thread
            eventThread = new JdiEventThread(vm);
            eventThread.start();

            // Start output capture
            startOutputCapture();
        }

        private void startOutputCapture() {
            if (vm.process() == null) return;
            Process process = vm.process();
            stdoutThread = new Thread(() -> captureOutput(process.getInputStream(), "stdout"), "stdout-capture");
            stdoutThread.setDaemon(true);
            stdoutThread.start();
            stderrThread = new Thread(() -> captureOutput(process.getErrorStream(), "stderr"), "stderr-capture");
            stderrThread.setDaemon(true);
            stderrThread.start();
        }

        private void captureOutput(InputStream is, String category) {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(is))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    Map<String, Object> body = new LinkedHashMap<>();
                    body.put("category", category);
                    body.put("output", line + "\n");
                    transport.sendEvent("output", body);
                }
            } catch (IOException e) {
                // Stream closed
            }
        }

        void configurationDone() {
            if (stopOnEntry) {
                // Don't resume — the VM starts suspended anyway
                // Just send a stopped event at entry
                stoppedThread = findMainThread();
                Map<String, Object> body = new LinkedHashMap<>();
                body.put("reason", "entry");
                body.put("threadId", stoppedThread != null ? (int) stoppedThread.uniqueID() : 1);
                body.put("allThreadsStopped", true);
                transport.sendEvent("stopped", body);
            } else {
                vm.resume();
                waitForStopAndNotify();
            }
        }

        void resume() {
            varPool.clear();
            lastException = null;
            stoppedThread = null;
            vm.resume();
        }

        void stepOver(int threadId) {
            varPool.clear();
            lastException = null;
            ThreadReference thread = stoppedThread;
            if (thread == null) thread = findMainThread();
            StepRequest req = vm.eventRequestManager().createStepRequest(
                thread, StepRequest.STEP_LINE, StepRequest.STEP_OVER);
            req.addCountFilter(1);
            req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
            req.enable();
            stoppedThread = null;
            vm.resume();
        }

        void stepInto(int threadId) {
            varPool.clear();
            lastException = null;
            ThreadReference thread = stoppedThread;
            if (thread == null) thread = findMainThread();
            StepRequest req = vm.eventRequestManager().createStepRequest(
                thread, StepRequest.STEP_LINE, StepRequest.STEP_INTO);
            req.addCountFilter(1);
            req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
            req.enable();
            stoppedThread = null;
            vm.resume();
        }

        void stepOut(int threadId) {
            varPool.clear();
            lastException = null;
            ThreadReference thread = stoppedThread;
            if (thread == null) thread = findMainThread();
            StepRequest req = vm.eventRequestManager().createStepRequest(
                thread, StepRequest.STEP_LINE, StepRequest.STEP_OUT);
            req.addCountFilter(1);
            req.setSuspendPolicy(EventRequest.SUSPEND_ALL);
            req.enable();
            stoppedThread = null;
            vm.resume();
        }

        void waitForStopAndNotify() {
            try {
                while (true) {
                    EventSet eventSet = eventThread.eventQueue.poll(30, TimeUnit.SECONDS);
                    if (eventSet == null) {
                        // Timeout — check if VM is still alive
                        try { vm.allThreads(); } catch (VMDisconnectedException e) {
                            transport.sendEvent("terminated", null);
                            transport.sendEvent("exited", Map.of("exitCode", 0));
                            return;
                        }
                        continue;
                    }

                    boolean shouldResume = true;
                    for (Event event : eventSet) {
                        if (event instanceof BreakpointEvent) {
                            BreakpointEvent bpEvent = (BreakpointEvent) event;
                            BreakpointRequest bpReq = (BreakpointRequest) bpEvent.request();

                            // Check condition
                            String condition = breakpointManager.getCondition(bpReq);
                            if (condition != null && !condition.isEmpty()) {
                                try {
                                    Value condVal = ExpressionEvaluator.evaluate(condition, bpEvent.thread(), 0, vm);
                                    if (condVal instanceof BooleanValue && !((BooleanValue) condVal).value()) {
                                        // Condition false — skip
                                        continue;
                                    }
                                } catch (Exception e) {
                                    // Condition evaluation failed — stop anyway
                                }
                            }

                            // Check hit condition
                            if (!breakpointManager.shouldStop(bpReq)) {
                                continue;
                            }

                            // Check logpoint
                            if (breakpointManager.isLogpoint(bpReq)) {
                                String logMsg = breakpointManager.getLogMessage(bpReq);
                                if (logMsg != null) {
                                    // Interpolate expressions in {}
                                    logMsg = interpolateLogMessage(logMsg, bpEvent.thread(), 0);
                                    Map<String, Object> body = new LinkedHashMap<>();
                                    body.put("category", "console");
                                    body.put("output", logMsg + "\n");
                                    transport.sendEvent("output", body);
                                }
                                continue; // Don't stop for logpoints
                            }

                            stoppedThread = bpEvent.thread();
                            shouldResume = false;
                            // Clean up one-shot step requests
                            deleteStepRequests();
                            Map<String, Object> body = new LinkedHashMap<>();
                            body.put("reason", "breakpoint");
                            body.put("threadId", (int) bpEvent.thread().uniqueID());
                            body.put("allThreadsStopped", true);
                            transport.sendEvent("stopped", body);
                        } else if (event instanceof StepEvent) {
                            StepEvent stepEvent = (StepEvent) event;
                            stoppedThread = stepEvent.thread();
                            shouldResume = false;
                            deleteStepRequests();
                            Map<String, Object> body = new LinkedHashMap<>();
                            body.put("reason", "step");
                            body.put("threadId", (int) stepEvent.thread().uniqueID());
                            body.put("allThreadsStopped", true);
                            transport.sendEvent("stopped", body);
                        } else if (event instanceof ExceptionEvent) {
                            ExceptionEvent exEvent = (ExceptionEvent) event;
                            lastException = exEvent.exception();
                            lastExceptionCaught = exEvent.catchLocation() != null;
                            stoppedThread = exEvent.thread();
                            shouldResume = false;
                            deleteStepRequests();
                            Map<String, Object> body = new LinkedHashMap<>();
                            body.put("reason", "exception");
                            body.put("threadId", (int) exEvent.thread().uniqueID());
                            body.put("allThreadsStopped", true);
                            body.put("text", exEvent.exception().referenceType().name());
                            transport.sendEvent("stopped", body);
                        } else if (event instanceof ClassPrepareEvent) {
                            ClassPrepareEvent cpEvent = (ClassPrepareEvent) event;
                            breakpointManager.resolveDeferred(cpEvent.referenceType(), transport);
                            // Also try to resolve function breakpoints
                            for (BreakpointManager.FuncBpEntry fb : breakpointManager.functionBreakpoints) {
                                if (!fb.verified) {
                                    breakpointManager.tryResolveFunctionBreakpoint(fb);
                                }
                            }
                            // Resume after class prepare — not a user-visible stop
                            continue;
                        } else if (event instanceof VMDeathEvent || event instanceof VMDisconnectEvent) {
                            transport.sendEvent("terminated", null);
                            Map<String, Object> exitBody = new LinkedHashMap<>();
                            exitBody.put("exitCode", 0);
                            transport.sendEvent("exited", exitBody);
                            return;
                        } else if (event instanceof ThreadStartEvent || event instanceof ThreadDeathEvent) {
                            // Thread lifecycle events — just continue
                            continue;
                        }
                    }

                    if (!shouldResume) return;
                    eventSet.resume();
                }
            } catch (InterruptedException e) {
                // Interrupted
            } catch (VMDisconnectedException e) {
                transport.sendEvent("terminated", null);
                transport.sendEvent("exited", Map.of("exitCode", 0));
            }
        }

        private String interpolateLogMessage(String msg, ThreadReference thread, int frameIndex) {
            StringBuilder result = new StringBuilder();
            int i = 0;
            while (i < msg.length()) {
                if (msg.charAt(i) == '{') {
                    int end = msg.indexOf('}', i);
                    if (end > i) {
                        String expr = msg.substring(i + 1, end);
                        try {
                            Value val = ExpressionEvaluator.evaluate(expr, thread, frameIndex, vm);
                            result.append(ExpressionEvaluator.valueToString(val, vm));
                        } catch (Exception e) {
                            result.append("{").append(expr).append("}");
                        }
                        i = end + 1;
                    } else {
                        result.append(msg.charAt(i++));
                    }
                } else {
                    result.append(msg.charAt(i++));
                }
            }
            return result.toString();
        }

        private void deleteStepRequests() {
            EventRequestManager erm = vm.eventRequestManager();
            for (StepRequest req : new ArrayList<>(erm.stepRequests())) {
                erm.deleteEventRequest(req);
            }
        }

        ThreadReference getStoppedThread() {
            if (stoppedThread != null) return stoppedThread;
            return findMainThread();
        }

        private ThreadReference findMainThread() {
            if (vm == null) return null;
            try {
                for (ThreadReference t : vm.allThreads()) {
                    if ("main".equals(t.name())) return t;
                }
                List<ThreadReference> threads = vm.allThreads();
                if (!threads.isEmpty()) return threads.get(0);
            } catch (VMDisconnectedException e) {
                // VM gone
            }
            return null;
        }

        void restart() throws Exception {
            // Shut down current VM — kill the process, don't just detach
            if (eventThread != null) eventThread.shutdown();
            // Clear all breakpoint state before disposing the old VM,
            // since old BreakpointRequest objects become invalid after dispose.
            breakpointManager.clearAll();
            try { vm.exit(0); } catch (Exception e) {
                // exit() may fail if VM is already gone; fall back to dispose
                try { vm.dispose(); } catch (Exception e2) { /* ignore */ }
            }
            // Wait for output capture threads to finish (they'll get IOException
            // when the old process's streams close)
            if (stdoutThread != null) {
                try { stdoutThread.join(2000); } catch (InterruptedException e) { /* ignore */ }
            }
            if (stderrThread != null) {
                try { stderrThread.join(2000); } catch (InterruptedException e) { /* ignore */ }
            }
            varPool.clear();
            lastException = null;
            stoppedThread = null;

            // Relaunch
            launch(savedClassName, savedClassPath, savedArgs, savedStopOnEntry, savedProgram);
        }

        void disconnect(boolean terminateDebuggee) {
            if (eventThread != null) eventThread.shutdown();
            if (vm != null) {
                try {
                    if (terminateDebuggee) {
                        vm.exit(0);
                    } else {
                        vm.dispose();
                    }
                } catch (VMDisconnectedException e) {
                    // Already disconnected
                }
            }
        }

        void shutdown() {
            disconnect(true);
        }
    }
}
