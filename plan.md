# Debug Server E2E Test — Bug Fix Plan

## Overview

4 bugs identified across 33 test scenarios. Fixing these brings partial-pass scenarios 13, 19, 28, and 30 to full pass. Scenarios that returned `NotSupported` are valid skips.

---

## Bug 1: `breakpoint_set_exception` CLI sends filters as string, server expects array

**Scenarios affected:** 19
**Files:** `src/debug/cli.zig`
**Severity:** Low (CLI argument serialization mismatch)

### Root Cause

The `--filters` argument is defined as `flag_string` (line 122), which serializes the value as a plain JSON string. The server (in `server.zig:676-677`) validates that `filters` is a JSON array and rejects strings.

### Fix

Add a new `ArgKind` variant `flag_string_list` that splits the flag value on commas and emits a JSON array of strings.

**Steps:**

1. **Add `flag_string_list` to `ArgKind` enum** (`cli.zig:10-18`)
   ```zig
   flag_string_list, // --name a,b,c → string array field
   ```

2. **Add serialization case** (after `flag_string` at `cli.zig:639-645`)
   ```zig
   .flag_string_list => {
       if (arg_def.flag) |flag| {
           if (flag_values.get(flag)) |val| {
               try jw.objectField(arg_def.json_name);
               try jw.beginArray();
               var iter = std.mem.splitScalar(u8, val, ',');
               while (iter.next()) |item| {
                   const trimmed = std.mem.trim(u8, item, " ");
                   if (trimmed.len > 0) try jw.write(trimmed);
               }
               try jw.endArray();
           }
       }
   },
   ```

3. **Update command definition** (`cli.zig:122`)
   - Change `.kind = .flag_string` to `.kind = .flag_string_list` for the `--filters` arg

---

## Bug 2: `step_over` enters function calls instead of stepping over them

**Scenarios affected:** 13
**Files:** `src/debug/dwarf/engine.zig`
**Severity:** High (core debugger feature broken)

### Root Cause

`step_over` (lines 724-759) sets a temporary breakpoint at the **next source line** address via `findNextLineAddress()`, then calls `continueExecution()`. This works only if execution flows linearly to the next line. When the current line contains a function call (e.g., `modify(&x, 3)`), execution branches into the called function. The temporary breakpoint at the next line is still set, but execution is now inside the callee — so the debugger reports a `step` stop inside the wrong function.

The `step_out` implementation (lines 760-803) already handles this correctly: it uses `getReturnAddress()` to set a breakpoint at the caller's return address, ensuring the function completes before stopping.

### Fix

Modify `step_over` to also set a breakpoint at the **return address** (where the current function will resume after a call), not just at the next line. This ensures that even if execution enters a called function, it will run to completion and return to the caller where the next-line breakpoint is waiting.

**Steps:**

1. **In the `step_over` handler** (`engine.zig:737-755`), after setting the temporary breakpoint at the next line address, also set a return-address breakpoint as a safety net:

   ```zig
   .step_over => {
       if (self.stepping_past_bp) |bp_addr| {
           try self.stepPastBreakpoint(bp_addr);
           self.stepping_past_bp = null;
       }
       if (options.granularity) |g| {
           if (g == .instruction) {
               try self.process.singleStep();
               return self.waitAndHandleStop();
           }
       }
       const regs = try self.process.readRegisters();
       const current_line = self.getLineForPC(regs.pc);
       if (current_line != null and self.line_entries.len > 0) {
           if (self.findNextLineAddress(regs.pc)) |next_addr| {
               const tmp_id = try self.bp_manager.setTemporary(next_addr);
               self.bp_manager.writeBreakpoint(tmp_id, &self.process) catch {
                   try self.process.singleStep();
                   return self.waitAndHandleStop();
               };

               // Also set a breakpoint at the return address so that if
               // execution enters a called function, we stop when it returns
               // back to this function's caller.
               const ret_addr = self.getReturnAddress(regs) catch null;
               var ret_tmp_id: ?u32 = null;
               if (ret_addr) |ra| {
                   if (ra != next_addr) {
                       ret_tmp_id = self.bp_manager.setTemporary(ra) catch null;
                       if (ret_tmp_id) |rid| {
                           self.bp_manager.writeBreakpoint(rid, &self.process) catch {
                               ret_tmp_id = null;
                           };
                       }
                   }
               }

               try self.process.continueExecution();
               const result = try self.waitAndHandleStop();
               self.bp_manager.cleanupTemporary(&self.process);

               // If we stopped at the return address (stepped out of current function),
               // we need to advance to the next source line like step_out does.
               if (ret_tmp_id != null and ret_addr != null) {
                   const post_regs = self.process.readRegisters() catch return result;
                   if (post_regs.pc == ret_addr.? or post_regs.pc == ret_addr.? + 4) {
                       // We're at the return site — advance to next line
                       if (self.findNextLineAddress(post_regs.pc)) |post_next| {
                           const tmp2 = try self.bp_manager.setTemporary(post_next);
                           self.bp_manager.writeBreakpoint(tmp2, &self.process) catch return result;
                           try self.process.continueExecution();
                           const result2 = try self.waitAndHandleStop();
                           self.bp_manager.cleanupTemporary(&self.process);
                           return result2;
                       }
                   }
               }

               return result;
           }
       }
       try self.process.singleStep();
   },
   ```

   **Key insight:** The return-address breakpoint serves as a safety net. If execution stays on the same line (no call), we hit the next-line BP first. If execution enters a function call, we hit the return-address BP when the call finishes, then advance to the next line — exactly like `step_out`'s Phase 2.

---

## Bug 3: Frame-relative variable inspection uses wrong register context

**Scenarios affected:** 28
**Files:** `src/debug/dwarf/engine.zig`, `src/debug/types.zig`
**Severity:** Medium (variable inspection in parent frames returns wrong values)

### Root Cause

`engineInspect` (line 1706) always uses the current frame's registers (`self.process.readRegisters()` at line 1730) to evaluate DWARF location expressions, even when inspecting a non-current frame. For `DW_OP_fbreg` (frame-base-relative) expressions, this means the frame base is computed using the current frame's FP register, not the target frame's FP. Variables at different stack depths have different frame pointers, so the wrong memory addresses are read.

The `buildStackTrace` function (line 1237) calls `unwindStackFP` which walks FP/LR pairs up the stack. Each frame's FP value is available during unwinding but is discarded — only the PC and metadata are kept in `types.StackFrame`.

### Fix

Preserve each frame's FP (and SP if available) during stack trace construction, then use them when evaluating variables for non-current frames.

**Steps:**

1. **Add `fp` field to `types.StackFrame`** (`types.zig`)
   ```zig
   fp: u64 = 0,  // Frame pointer for this frame (used for variable inspection)
   ```

2. **Populate `fp` during stack trace construction** (`engine.zig`, in `buildStackTrace` around line 1301)
   - The `unwind.UnwindFrame` already contains the frame's address (PC). The FP for each frame is available during FP unwinding — it's the `fp` value used to read `[fp]` for the next frame. Add `fp` to `UnwindFrame` and propagate it through.
   - Alternatively, since FP unwinding walks `fp → [fp] → [[fp]] → ...`, the FP for frame N is known: frame 0's FP = `regs.fp`, frame 1's FP = memory at `[frame0.fp]`, etc. Store this in the StackFrame.

3. **Use frame-specific FP in `engineInspect`** (`engine.zig:1899-1901`)
   - When `request.frame_id` is set and matches a non-zero frame, look up that frame's stored FP from `self.cached_stack_trace`
   - Create a modified `RegisterState` with the target frame's FP substituted
   - Pass this to `RegisterAdapter` instead of the current registers

   ```zig
   // 8. Build register adapter — use target frame's registers if inspecting non-current frame
   var target_regs = regs;
   if (request.frame_id) |frame_id| {
       if (frame_id != 0) {
           for (self.cached_stack_trace) |frame| {
               if (frame.id == frame_id and frame.fp != 0) {
                   target_regs.fp = frame.fp;
                   break;
               }
           }
       }
   }
   var reg_adapter = RegisterAdapter{ .regs = target_regs };
   ```

4. **Apply same fix in `buildScopeResult`** if it has the same pattern (uses current regs for non-current frames).

---

## Bug 4: `poll_events` returns empty because stdout pipes close before drain

**Scenarios affected:** 30
**Files:** `src/debug/dwarf/process_mach.zig`, `src/debug/dwarf/engine.zig`
**Severity:** Medium (output events lost on process exit/signal)

### Root Cause

In `waitForStop()` (process_mach.zig:245-288), when the process exits or receives a signal, the stdout/stderr pipe file descriptors are immediately closed and set to null. After this, `readCapturedOutput()` returns null because the pipe FD is gone. When `poll_events` later calls `engineDrainNotifications`, there's nothing to read.

The output was written to the pipe by the child process **before** exiting, so the data is in the kernel pipe buffer. It just needs to be read before the FD is closed.

### Fix

Drain the pipe buffers before closing them in `waitForStop()`.

**Steps:**

1. **In `waitForStop()`** (`process_mach.zig:252-264` and `267-279`), read remaining pipe data before closing:

   ```zig
   // Before closing, drain any remaining output
   if (self.stdout_pipe_read) |fd| {
       self.drainPipeToBuffer(fd);  // read remaining data into internal buffer
       posix.close(fd);
       self.stdout_pipe_read = null;
   }
   ```

2. **Add an internal output buffer** to `MachProcessControl`:
   ```zig
   pending_stdout: ?[]const u8 = null,
   ```

3. **Add `drainPipeToBuffer` method** that reads all available data from the pipe FD into `pending_stdout` using non-blocking reads.

4. **Update `readCapturedOutput`** to return data from `pending_stdout` if the pipe is closed but buffered data remains:
   ```zig
   pub fn readCapturedOutput(self: *MachProcessControl, allocator: std.mem.Allocator) !?[]const u8 {
       // First check for buffered output from closed pipes
       if (self.pending_stdout) |data| {
           self.pending_stdout = null;
           return data;
       }
       // Then try live pipe read
       const fd = self.stdout_pipe_read orelse return null;
       // ... existing non-blocking read logic ...
   }
   ```

---

## Tests Expected to be Skipped

These tests return `NotSupported` which is valid behavior documented in the test spec:

| Scenario | Feature | Skip Reason |
|----------|---------|-------------|
| 21 | Step-in targets | Native engine does not implement step-in target enumeration |
| 29 | Watchpoints (data breakpoints) | Not supported on macOS ARM64 (hardware limitation) |
| 31 | Cancel / terminate threads | Native engine does not implement cancel or thread termination |
| 32 | Restart frame | Native engine does not implement frame restart |

---

## Implementation Order

1. **Bug 1** (filters serialization) — smallest, self-contained, no risk of regression
2. **Bug 4** (pipe drain race) — isolated to process_mach.zig, straightforward
3. **Bug 2** (step_over) — core engine change, moderate complexity
4. **Bug 3** (frame-relative inspection) — requires plumbing FP through stack trace, most invasive

After each fix, re-run the affected scenario to verify.
