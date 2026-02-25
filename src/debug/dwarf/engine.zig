const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const process_mod = @import("process.zig");
const breakpoint_mod = @import("breakpoints.zig");
const binary_macho = @import("binary_macho.zig");
const binary_elf = @import("binary_elf.zig");
const parser = @import("parser.zig");
const location = @import("location.zig");
const unwind = @import("unwind.zig");
const core_dump_mod = @import("core_dump.zig");

const ProcessControl = process_mod.ProcessControl;
const StopState = types.StopState;
const StopReason = types.StopReason;
const RunAction = types.RunAction;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;
const ActiveDriver = driver_mod.ActiveDriver;
const DriverVTable = driver_mod.DriverVTable;
const BreakpointManager = breakpoint_mod.BreakpointManager;
const InstructionBreakpoint = types.InstructionBreakpoint;

// ── DWARF Debug Engine ──────────────────────────────────────────────────

const HardwareWatchpoint = struct {
    active: bool = false,
    id: u32 = 0, // breakpoint ID (slot + 1000)
    address: u64 = 0, // watched memory address
    size: u64 = 0, // watch region size in bytes
    access_type: u3 = 0, // WCR access bits (1=load, 2=store, 3=both)
};

pub const DwarfEngine = struct {
    process: ProcessControl = .{},
    allocator: std.mem.Allocator,
    launched: bool = false,
    program_path: ?[]const u8 = null,
    bp_manager: BreakpointManager,
    line_entries: []parser.LineEntry = &.{},
    file_entries: []parser.FileEntry = &.{},
    allocated_paths: [][]const u8 = &.{},
    functions: []parser.FunctionInfo = &.{},
    inlined_subs: []parser.InlinedSubroutineInfo = &.{},
    binary: ?binary_macho.MachoBinary = null,
    dsym_binary: ?binary_macho.MachoBinary = null,
    elf_binary: ?binary_elf.ElfBinary = null,
    aslr_slide: i64 = 0,
    /// Track whether we just hit a breakpoint and need to step past it
    stepping_past_bp: ?u64 = null,
    /// Hardware watchpoint tracking (ARM64 supports up to 4 slots on Apple Silicon)
    hw_watchpoints: [4]HardwareWatchpoint = [_]HardwareWatchpoint{.{}} ** 4,
    /// Track whether we need to step past a watchpoint on next resume (slot index)
    stepping_past_wp: ?u32 = null,
    /// Track whether a step operation is in progress (for stop_reason reporting)
    step_in_progress: bool = false,
    /// Track whether a single-step operation is in progress (for SIGURG re-step)
    is_single_stepping: bool = false,
    /// Exception breakpoint signal filters (e.g. SIGSEGV=11, SIGFPE=8)
    exception_signals: [32]bool = [_]bool{false} ** 32,
    /// Cached stack trace from last stop (for per-frame inspection)
    cached_stack_trace: []const types.StackFrame = &.{},
    /// Condition evaluation context (stored on engine to outlive buildConditionEvaluator call)
    condition_context: ?ConditionContext = null,
    /// Parsed .debug_names index for accelerated symbol lookup
    debug_names_index: ?parser.DebugNamesIndex = null,
    /// Parsed .debug_macro definitions for macro expansion
    macro_defs: []parser.MacroDef = &.{},
    /// Split DWARF: loaded .dwo binaries for debug fission
    dwo_binaries: []binary_macho.MachoBinary = &.{},
    dwo_elf_binaries: []binary_elf.ElfBinary = &.{},
    /// Type units: signature-to-offset mapping for DW_FORM_ref_sig8
    type_units: []parser.TypeUnitEntry = &.{},
    /// Split DWARF: skeleton CU info for matching DWO binaries
    skeleton_cus: []const parser.SkeletonCuInfo = &.{},
    /// Pre-built FDE index for fast PC-to-FDE lookup in eh_frame/debug_frame
    eh_frame_index: ?unwind.EhFrameIndex = null,
    /// Whether the frame data comes from .debug_frame (vs .eh_frame)
    is_debug_frame: bool = false,
    /// CIE cache to avoid re-parsing CIEs during CFA unwinding
    cie_cache: ?unwind.CieCache = null,
    /// Abbreviation table cache to avoid re-parsing on every parseScopedVariables call
    abbrev_cache: ?parser.AbbrevCache = null,
    /// CU index for fast PC-to-CU lookup
    cu_index: []parser.CuIndexEntry = &.{},
    /// Type DIE cache per compilation unit
    type_die_cache: ?parser.TypeDieCache = null,
    /// Core dump for post-mortem debugging (no live process)
    core_dump: ?core_dump_mod.CoreDump = null,

    pub fn init(allocator: std.mem.Allocator) DwarfEngine {
        return .{
            .allocator = allocator,
            .bp_manager = BreakpointManager.init(allocator),
        };
    }

    pub fn deinit(self: *DwarfEngine) void {
        // Clear hardware watchpoints before killing to leave clean state
        if (self.core_dump == null) {
            for (self.hw_watchpoints, 0..) |wp, slot| {
                if (wp.active) {
                    self.process.clearHardwareWatchpoint(@intCast(slot)) catch {};
                }
            }
        }
        if (self.core_dump) |*cd| cd.deinit();
        if (self.core_dump == null) self.process.kill() catch {};
        if (self.program_path) |p| self.allocator.free(p);
        self.bp_manager.deinit();
        if (self.line_entries.len > 0) self.allocator.free(self.line_entries);
        for (self.allocated_paths) |p| self.allocator.free(@constCast(p));
        if (self.allocated_paths.len > 0) self.allocator.free(self.allocated_paths);
        if (self.file_entries.len > 0) self.allocator.free(self.file_entries);
        if (self.functions.len > 0) self.allocator.free(self.functions);
        if (self.inlined_subs.len > 0) self.allocator.free(self.inlined_subs);
        if (self.cached_stack_trace.len > 0) self.allocator.free(self.cached_stack_trace);
        if (self.condition_context) |*ctx| ctx.deinit();
        if (self.debug_names_index) |*idx| idx.deinit(self.allocator);
        if (self.macro_defs.len > 0) self.allocator.free(self.macro_defs);
        for (self.dwo_binaries) |*b| {
            var bin = b.*;
            bin.deinit(self.allocator);
        }
        if (self.dwo_binaries.len > 0) self.allocator.free(self.dwo_binaries);
        for (self.dwo_elf_binaries) |*b| {
            var bin = b.*;
            bin.deinit(self.allocator);
        }
        if (self.dwo_elf_binaries.len > 0) self.allocator.free(self.dwo_elf_binaries);
        if (self.type_units.len > 0) self.allocator.free(self.type_units);
        if (self.skeleton_cus.len > 0) self.allocator.free(self.skeleton_cus);
        if (self.type_die_cache) |*tdc| tdc.deinit(self.allocator);
        if (self.cu_index.len > 0) self.allocator.free(self.cu_index);
        if (self.eh_frame_index) |*idx| idx.deinit(self.allocator);
        if (self.cie_cache) |*cc| cc.deinit(self.allocator);
        if (self.abbrev_cache) |*ac| ac.deinit(self.allocator);
        if (self.dsym_binary) |*b| b.deinit(self.allocator);
        if (self.binary) |*b| b.deinit(self.allocator);
        if (self.elf_binary) |*b| b.deinit(self.allocator);
    }

    pub fn activeDriver(self: *DwarfEngine) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .native,
        };
    }

    const vtable = DriverVTable{
        .launchFn = engineLaunch,
        .runFn = engineRun,
        .setBreakpointFn = engineSetBreakpoint,
        .removeBreakpointFn = engineRemoveBreakpoint,
        .listBreakpointsFn = engineListBreakpoints,
        .inspectFn = engineInspect,
        .stopFn = engineStop,
        .deinitFn = engineDeinit,
        .threadsFn = engineThreads,
        .stackTraceFn = engineStackTrace,
        .readMemoryFn = engineReadMemory,
        .writeMemoryFn = engineWriteMemory,
        .disassembleFn = engineDisassemble,
        .attachFn = engineAttach,
        .setFunctionBreakpointFn = engineSetFunctionBreakpoint,
        .setExceptionBreakpointsFn = engineSetExceptionBreakpoints,
        .setVariableFn = engineSetVariable,
        .gotoFn = engineGoto,
        .scopesFn = engineScopes,
        .dataBreakpointInfoFn = engineDataBreakpointInfo,
        .setDataBreakpointFn = engineSetDataBreakpoint,
        .capabilitiesFn = engineCapabilities,
        .completionsFn = engineCompletions,
        .modulesFn = engineModules,
        .loadedSourcesFn = engineLoadedSources,
        .sourceFn = engineSource,
        .setExpressionFn = engineSetExpression,
        .terminateFn = engineTerminate,
        .restartFrameFn = engineRestartFrame,
        .exceptionInfoFn = engineExceptionInfo,
        .readRegistersFn = engineReadRegisters,
        .gotoTargetsFn = engineGotoTargets,
        .findSymbolFn = engineFindSymbol,
        .setInstructionBreakpointsFn = engineSetInstructionBreakpoints,
        .breakpointLocationsFn = engineBreakpointLocations,
        .restartFn = engineRestart,
        .writeRegistersFn = engineWriteRegisters,
        .variableLocationFn = engineVariableLocation,
        .drainNotificationsFn = engineDrainNotifications,
        .loadCoreFn = engineLoadCore,
        .stepInTargetsFn = engineStepInTargets,
        .getPidFn = engineGetPid,
        .cancelFn = engineCancel,
        .terminateThreadsFn = engineTerminateThreads,
    };

    // ── Launch ──────────────────────────────────────────────────────

    fn engineLaunch(ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        try self.process.spawn(allocator, config.program, config.args);
        self.launched = true;
        self.program_path = try allocator.dupe(u8, config.program);

        // Load binary and parse DWARF line tables for breakpoint resolution
        self.loadDebugInfo(config.program) catch {};

        // Compute ASLR slide and adjust line entry addresses
        self.applyAslrSlide() catch {};
    }

    fn applyAslrSlide(self: *DwarfEngine) !void {
        if (self.line_entries.len == 0) return;
        const binary = self.binary orelse return;
        if (binary.text_vmaddr == 0) return;

        const actual_base = self.process.getTextBase() catch return;
        if (actual_base == binary.text_vmaddr) return; // no slide

        const slide: i64 = @as(i64, @intCast(actual_base)) - @as(i64, @intCast(binary.text_vmaddr));
        self.aslr_slide = slide;

        for (self.line_entries) |*entry| {
            if (slide > 0) {
                entry.address +%= @intCast(@as(u64, @intCast(slide)));
            } else {
                entry.address -%= @intCast(@as(u64, @intCast(-slide)));
            }
        }

        // Also adjust function addresses
        for (self.functions) |*func| {
            if (slide > 0) {
                func.low_pc +%= @intCast(@as(u64, @intCast(slide)));
                if (func.high_pc > 0) func.high_pc +%= @intCast(@as(u64, @intCast(slide)));
            } else {
                func.low_pc -%= @intCast(@as(u64, @intCast(-slide)));
                if (func.high_pc > 0) func.high_pc -%= @intCast(@as(u64, @intCast(-slide)));
            }
        }

        // Also adjust inlined subroutine addresses
        for (self.inlined_subs) |*isub| {
            if (slide > 0) {
                if (isub.low_pc > 0) isub.low_pc +%= @intCast(@as(u64, @intCast(slide)));
                if (isub.high_pc > 0) isub.high_pc +%= @intCast(@as(u64, @intCast(slide)));
            } else {
                if (isub.low_pc > 0) isub.low_pc -%= @intCast(@as(u64, @intCast(-slide)));
                if (isub.high_pc > 0) isub.high_pc -%= @intCast(@as(u64, @intCast(-slide)));
            }
        }

    }

    fn loadDebugInfo(self: *DwarfEngine, program: []const u8) !void {
        if (builtin.os.tag == .macos) {
            self.loadDebugInfoMachO(program);
        } else if (builtin.os.tag == .linux) {
            self.loadDebugInfoElf(program);
        }

        // Build FDE index for fast CFA unwinding
        if (self.resolveFrameData()) |eh_frame_data| {
            self.eh_frame_index = unwind.buildEhFrameIndex(eh_frame_data, self.is_debug_frame, self.allocator) catch null;
            if (self.eh_frame_index != null) {
                self.cie_cache = .{};
            }
        }

        // Initialize abbreviation cache for parseScopedVariables
        self.abbrev_cache = .{};

        // Initialize type DIE cache for parseScopedVariables
        self.type_die_cache = .{};

        // Build CU index for fast PC-to-CU lookup
        if (self.resolveDebugData()) |dd| {
            self.cu_index = parser.buildCuIndex(dd.info_data, dd.abbrev_data, self.allocator) catch &.{};
        }

        // Sort line entries and functions for binary search lookups
        if (self.line_entries.len > 0) {
            std.mem.sort(parser.LineEntry, self.line_entries, {}, struct {
                fn lessThan(_: void, a: parser.LineEntry, b: parser.LineEntry) bool {
                    return a.address < b.address;
                }
            }.lessThan);
        }
        if (self.functions.len > 0) {
            std.mem.sort(parser.FunctionInfo, self.functions, {}, struct {
                fn lessThan(_: void, a: parser.FunctionInfo, b: parser.FunctionInfo) bool {
                    return a.low_pc < b.low_pc;
                }
            }.lessThan);
        }
    }

    fn loadDebugInfoMachO(self: *DwarfEngine, program: []const u8) void {
        var binary = binary_macho.MachoBinary.loadFile(self.allocator, program) catch return;
        errdefer binary.deinit(self.allocator);

        // Try loading debug_line from the binary itself (with transparent decompression)
        if (binary.sections.debug_line) |line_section| {
            const line_data = (binary.getSectionDataAlloc(self.allocator, line_section) catch null) orelse binary.getSectionData(line_section);
            if (line_data) |ld| {
                const line_str_data = if (binary.sections.debug_line_str) |ls|
                    (binary.getSectionDataAlloc(self.allocator, ls) catch null) orelse binary.getSectionData(ls)
                else
                    null;
                const result = parser.parseLineProgramWithFilesEx(ld, self.allocator, line_str_data) catch {
                    // Fallback to old method
                    const entries = parser.parseLineProgram(ld, self.allocator) catch return;
                    if (entries.len > 0) {
                        self.line_entries = entries;
                    }
                    return;
                };
                if (result.line_entries.len > 0) {
                    self.line_entries = result.line_entries;
                    if (result.file_entries.len > 0) {
                        self.file_entries = result.file_entries;
                    }
                    if (result.allocated_paths.len > 0) {
                        self.allocated_paths = result.allocated_paths;
                    }
                }
            }
        }

        // Fallback: on macOS, Apple clang stores DWARF in a .dSYM bundle
        if (self.line_entries.len == 0) {
            self.loadDsymDebugInfo(program) catch {};
        }

        // Parse function info from debug_info + debug_abbrev
        self.loadFunctionInfo(&binary);

        self.binary = binary;
    }

    fn loadDebugInfoElf(self: *DwarfEngine, program: []const u8) void {
        var elf = binary_elf.ElfBinary.loadFile(self.allocator, program) catch return;
        errdefer elf.deinit(self.allocator);

        // Load debug_line (with transparent decompression)
        if (elf.sections.debug_line) |line_section| {
            const line_data = (elf.getSectionDataAlloc(self.allocator, line_section) catch null) orelse elf.getSectionData(line_section);
            if (line_data) |ld| {
                const line_str_data = if (elf.sections.debug_line_str) |ls|
                    (elf.getSectionDataAlloc(self.allocator, ls) catch null) orelse elf.getSectionData(ls)
                else
                    null;
                const result = parser.parseLineProgramWithFilesEx(ld, self.allocator, line_str_data) catch {
                    const entries = parser.parseLineProgram(ld, self.allocator) catch return;
                    if (entries.len > 0) {
                        self.line_entries = entries;
                    }
                    return;
                };
                if (result.line_entries.len > 0) {
                    self.line_entries = result.line_entries;
                    if (result.file_entries.len > 0) {
                        self.file_entries = result.file_entries;
                    }
                    if (result.allocated_paths.len > 0) {
                        self.allocated_paths = result.allocated_paths;
                    }
                }
            }
        }

        // Parse function info from debug_info + debug_abbrev
        self.loadFunctionInfoElf(&elf);

        self.elf_binary = elf;

    }

    fn loadFunctionInfo(self: *DwarfEngine, binary: *binary_macho.MachoBinary) void {
        // Try dSYM first, then main binary
        const debug_binary: *binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (binary.sections.debug_info != null) break :blk binary;
            return;
        };

        const info_section = debug_binary.sections.debug_info orelse return;
        const abbrev_section = debug_binary.sections.debug_abbrev orelse return;
        const info_data = (debug_binary.getSectionDataAlloc(self.allocator, info_section) catch null) orelse debug_binary.getSectionData(info_section) orelse return;
        const abbrev_data = (debug_binary.getSectionDataAlloc(self.allocator, abbrev_section) catch null) orelse debug_binary.getSectionData(abbrev_section) orelse return;
        const str_data = if (debug_binary.sections.debug_str) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null;

        const functions = parser.parseCompilationUnitEx(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null,
            },
            self.allocator,
        ) catch return;

        if (functions.len > 0) {
            self.functions = functions;
        }

        // Also parse inlined subroutines
        const extra_sections = parser.ExtraSections{
            .debug_str_offsets = str_offsets_data,
            .debug_addr = addr_data,
            .debug_ranges = if (debug_binary.sections.debug_ranges) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null,
            .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| (debug_binary.getSectionDataAlloc(self.allocator, s) catch null) orelse debug_binary.getSectionData(s) else null,
        };
        const inlined = parser.parseInlinedSubroutines(
            info_data,
            abbrev_data,
            str_data,
            extra_sections,
            self.allocator,
        ) catch return;
        if (inlined.len > 0) {
            self.inlined_subs = inlined;
        }

        // Load .debug_names index for accelerated symbol lookup
        if (debug_binary.sections.debug_names) |names_section| {
            if ((debug_binary.getSectionDataAlloc(self.allocator, names_section) catch null) orelse debug_binary.getSectionData(names_section)) |names_data| {
                self.debug_names_index = parser.parseDebugNames(names_data, str_data, self.allocator) catch null;
            }
        }

        // Load .debug_macro for macro expansion
        if (debug_binary.sections.debug_macro) |macro_section| {
            if ((debug_binary.getSectionDataAlloc(self.allocator, macro_section) catch null) orelse debug_binary.getSectionData(macro_section)) |macro_data| {
                self.macro_defs = parser.parseDebugMacro(
                    macro_data,
                    str_data,
                    str_offsets_data,
                    0,
                    false,
                    self.allocator,
                ) catch &.{};
            }
        }

        // Parse type units for DW_FORM_ref_sig8 resolution
        self.type_units = parser.parseTypeUnits(info_data, self.allocator) catch &.{};

        // Detect and load Split DWARF .dwo files
        const skeletons = parser.detectSplitDwarf(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
            },
            self.allocator,
        ) catch &.{};

        if (skeletons.len > 0) {
            self.skeleton_cus = skeletons;
            var dwo_list = std.ArrayListUnmanaged(binary_macho.MachoBinary).empty;
            // Attempt to load each .dwo file
            for (skeletons) |skel| {
                // Construct full path: comp_dir/dwo_name
                const dwo_path = if (skel.comp_dir.len > 0)
                    std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ skel.comp_dir, skel.dwo_name }) catch continue
                else
                    self.allocator.dupe(u8, skel.dwo_name) catch continue;
                defer self.allocator.free(dwo_path);

                // Try to load as Mach-O .dwo
                const dwo_binary = binary_macho.MachoBinary.loadFile(self.allocator, dwo_path) catch continue;
                dwo_list.append(self.allocator, dwo_binary) catch continue;
            }
            if (dwo_list.items.len > 0) {
                self.dwo_binaries = dwo_list.toOwnedSlice(self.allocator) catch &.{};
            }

            // Parse functions from DWO binaries and merge
            for (self.dwo_binaries) |dwo| {
                const dwo_info = if (dwo.sections.debug_info) |s| dwo.getSectionData(s) orelse continue else continue;
                const dwo_abbrev = if (dwo.sections.debug_abbrev) |s| dwo.getSectionData(s) orelse continue else continue;
                const dwo_str = if (dwo.sections.debug_str) |s| dwo.getSectionData(s) else null;
                const dwo_funcs = parser.parseCompilationUnitEx(
                    dwo_info,
                    dwo_abbrev,
                    dwo_str,
                    .{
                        .debug_str_offsets = if (dwo.sections.debug_str_offsets) |s| dwo.getSectionData(s) else null,
                        .debug_addr = addr_data,
                        .debug_ranges = if (dwo.sections.debug_ranges) |s| dwo.getSectionData(s) else null,
                        .debug_rnglists = if (dwo.sections.debug_rnglists) |s| dwo.getSectionData(s) else null,
                    },
                    self.allocator,
                ) catch continue;
                if (dwo_funcs.len > 0 and self.functions.len == 0) {
                    self.functions = dwo_funcs;
                } else if (dwo_funcs.len > 0) {
                    self.allocator.free(dwo_funcs);
                }
            }
        }
    }

    fn loadFunctionInfoElf(self: *DwarfEngine, elf: *binary_elf.ElfBinary) void {
        const info_section = elf.sections.debug_info orelse return;
        const abbrev_section = elf.sections.debug_abbrev orelse return;
        const info_data = (elf.getSectionDataAlloc(self.allocator, info_section) catch null) orelse elf.getSectionData(info_section) orelse return;
        const abbrev_data = (elf.getSectionDataAlloc(self.allocator, abbrev_section) catch null) orelse elf.getSectionData(abbrev_section) orelse return;
        const str_data = if (elf.sections.debug_str) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null;
        const str_offsets_data = if (elf.sections.debug_str_offsets) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null;
        const addr_data = if (elf.sections.debug_addr) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null;

        const functions = parser.parseCompilationUnitEx(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (elf.sections.debug_ranges) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
                .debug_rnglists = if (elf.sections.debug_rnglists) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            },
            self.allocator,
        ) catch return;

        if (functions.len > 0) {
            self.functions = functions;
        }

        // Also parse inlined subroutines
        const elf_extra = parser.ExtraSections{
            .debug_str_offsets = str_offsets_data,
            .debug_addr = addr_data,
            .debug_ranges = if (elf.sections.debug_ranges) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .debug_rnglists = if (elf.sections.debug_rnglists) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
        };
        const inlined = parser.parseInlinedSubroutines(
            info_data,
            abbrev_data,
            str_data,
            elf_extra,
            self.allocator,
        ) catch return;
        if (inlined.len > 0) {
            self.inlined_subs = inlined;
        }

        // Load .debug_names index for accelerated symbol lookup
        if (elf.sections.debug_names) |names_section| {
            if ((elf.getSectionDataAlloc(self.allocator, names_section) catch null) orelse elf.getSectionData(names_section)) |names_data| {
                self.debug_names_index = parser.parseDebugNames(names_data, str_data, self.allocator) catch null;
            }
        }

        // Load .debug_macro for macro expansion
        if (elf.sections.debug_macro) |macro_section| {
            if ((elf.getSectionDataAlloc(self.allocator, macro_section) catch null) orelse elf.getSectionData(macro_section)) |macro_data| {
                self.macro_defs = parser.parseDebugMacro(
                    macro_data,
                    str_data,
                    str_offsets_data,
                    0,
                    false,
                    self.allocator,
                ) catch &.{};
            }
        }

        // Parse type units for DW_FORM_ref_sig8 resolution
        if (self.type_units.len == 0) {
            self.type_units = parser.parseTypeUnits(info_data, self.allocator) catch &.{};
        }

        // Detect and load Split DWARF .dwo files
        const elf_skeletons = parser.detectSplitDwarf(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
            },
            self.allocator,
        ) catch &.{};

        if (elf_skeletons.len > 0) {
            if (self.skeleton_cus.len == 0) {
                self.skeleton_cus = elf_skeletons;
            } else {
                self.allocator.free(elf_skeletons);
            }
            var dwo_elf_list = std.ArrayListUnmanaged(binary_elf.ElfBinary).empty;
            for (self.skeleton_cus) |skel| {
                const dwo_path = if (skel.comp_dir.len > 0)
                    std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ skel.comp_dir, skel.dwo_name }) catch continue
                else
                    self.allocator.dupe(u8, skel.dwo_name) catch continue;
                defer self.allocator.free(dwo_path);

                const dwo_binary = binary_elf.ElfBinary.loadFile(self.allocator, dwo_path) catch continue;
                dwo_elf_list.append(self.allocator, dwo_binary) catch continue;
            }
            if (dwo_elf_list.items.len > 0) {
                self.dwo_elf_binaries = dwo_elf_list.toOwnedSlice(self.allocator) catch &.{};
            }

            // Parse functions from DWO ELF binaries and merge
            for (self.dwo_elf_binaries) |dwo_elf| {
                const dwo_info = if (dwo_elf.sections.debug_info) |s| dwo_elf.getSectionData(s) orelse continue else continue;
                const dwo_abbrev = if (dwo_elf.sections.debug_abbrev) |s| dwo_elf.getSectionData(s) orelse continue else continue;
                const dwo_str = if (dwo_elf.sections.debug_str) |s| dwo_elf.getSectionData(s) else null;
                const dwo_funcs = parser.parseCompilationUnitEx(
                    dwo_info,
                    dwo_abbrev,
                    dwo_str,
                    .{
                        .debug_str_offsets = if (dwo_elf.sections.debug_str_offsets) |s| dwo_elf.getSectionData(s) else null,
                        .debug_addr = addr_data,
                        .debug_ranges = if (dwo_elf.sections.debug_ranges) |s| dwo_elf.getSectionData(s) else null,
                        .debug_rnglists = if (dwo_elf.sections.debug_rnglists) |s| dwo_elf.getSectionData(s) else null,
                    },
                    self.allocator,
                ) catch continue;
                if (dwo_funcs.len > 0 and self.functions.len == 0) {
                    self.functions = dwo_funcs;
                } else if (dwo_funcs.len > 0) {
                    self.allocator.free(dwo_funcs);
                }
            }
        }
    }

    fn loadDsymDebugInfo(self: *DwarfEngine, program: []const u8) !void {
        // dSYM path: <program>.dSYM/Contents/Resources/DWARF/<basename>
        const basename = std.fs.path.basename(program);

        const dsym_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.dSYM/Contents/Resources/DWARF/{s}",
            .{ program, basename },
        );
        defer self.allocator.free(dsym_path);

        var dsym_binary = binary_macho.MachoBinary.loadFile(self.allocator, dsym_path) catch return;
        errdefer dsym_binary.deinit(self.allocator);

        if (dsym_binary.sections.debug_line) |line_section| {
            const line_data = (dsym_binary.getSectionDataAlloc(self.allocator, line_section) catch null) orelse dsym_binary.getSectionData(line_section);
            if (line_data) |ld| {
                const line_str_data = if (dsym_binary.sections.debug_line_str) |ls|
                    (dsym_binary.getSectionDataAlloc(self.allocator, ls) catch null) orelse dsym_binary.getSectionData(ls)
                else
                    null;
                const result = parser.parseLineProgramWithFilesEx(ld, self.allocator, line_str_data) catch {
                    const entries = parser.parseLineProgram(ld, self.allocator) catch return;
                    if (entries.len > 0) {
                        self.line_entries = entries;
                    }
                    return;
                };
                if (result.line_entries.len > 0) {
                    self.line_entries = result.line_entries;
                    if (result.file_entries.len > 0) {
                        self.file_entries = result.file_entries;
                    }
                    if (result.allocated_paths.len > 0) {
                        self.allocated_paths = result.allocated_paths;
                    }
                }
            }
        }

        self.dsym_binary = dsym_binary;
    }

    // ── Run ─────────────────────────────────────────────────────────

    fn engineRun(ctx: *anyopaque, _: std.mem.Allocator, action: RunAction, options: types.RunOptions) anyerror!StopState {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.core_dump != null) return error.NotSupported; // core dumps are read-only
        // Track step operations for stop_reason reporting
        self.step_in_progress = switch (action) {
            .step_into, .step_over, .step_out, .step_back => true,
            else => false,
        };
        switch (action) {
            .@"continue" => {
                // If we're stopped at a watchpoint, step past it first
                if (self.stepping_past_wp) |wp_slot| {
                    try self.stepPastWatchpoint(wp_slot);
                    self.stepping_past_wp = null;
                }
                // If we're stopped at a breakpoint, step past it first
                if (self.stepping_past_bp) |bp_addr| {
                    try self.stepPastBreakpoint(bp_addr);
                    self.stepping_past_bp = null;
                }
                try self.process.continueExecution();
            },
            .step_into => {
                if (self.stepping_past_wp) |wp_slot| {
                    try self.stepPastWatchpoint(wp_slot);
                    self.stepping_past_wp = null;
                }
                if (self.stepping_past_bp) |bp_addr| {
                    try self.stepPastBreakpoint(bp_addr);
                    self.stepping_past_bp = null;
                }
                // Instruction-level granularity: just single step
                if (options.granularity) |g| {
                    if (g == .instruction) {
                        self.is_single_stepping = true;
                        try self.process.singleStep();
                        const result = try self.waitAndHandleStop();
                        self.is_single_stepping = false;
                        return result;
                    }
                }
                // Line-level step_into: single-step instruction by instruction until
                // either we enter a new function or reach a different source line.
                const pre_regs = try self.process.readRegisters();
                const pre_func = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, pre_regs.pc) else "";
                const pre_line = self.getLineForPC(pre_regs.pc);
                const max_steps: u32 = 2000;
                var step_count: u32 = 0;

                while (step_count < max_steps) {
                    try self.process.singleStep();
                    step_count += 1;
                    const step_result = try self.process.waitForStop();
                    switch (step_result.status) {
                        .exited => return .{ .stop_reason = .exited, .exit_code = step_result.exit_code },
                        .stopped => {
                            // Handle non-fatal signals (e.g. SIGURG from Go runtime) by re-stepping
                            const SIGTRAP_INNER = 5;
                            if (step_result.signal != SIGTRAP_INNER and step_result.signal > 0 and step_result.signal < 32) {
                                if (!self.exception_signals[@intCast(step_result.signal)] and !isFatalSignal(@intCast(step_result.signal))) {
                                    // Non-fatal signal — re-step without counting
                                    continue;
                                }
                            }
                            const post_regs = self.process.readRegisters() catch return self.handleStop(step_result.signal);
                            const post_func = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, post_regs.pc) else "";

                            // Check if we entered a new function
                            const entered_new_func = post_func.len > 0 and
                                !std.mem.eql(u8, post_func, "<unknown>") and
                                !std.mem.eql(u8, post_func, pre_func);

                            if (entered_new_func) {
                                // Skip Go runtime trampolines (morestack, gogo, etc.)
                                // These sit between user function calls during stack growth.
                                // Continue single-stepping — morestack will eventually jump
                                // back to the target function's entry point.
                                if (isRuntimeTrampoline(post_func)) {
                                    continue;
                                }
                                // Find the prologue end address for the new function
                                if (self.findPrologueEndAddress(post_regs.pc)) |prologue_addr| {
                                    if (prologue_addr != post_regs.pc) {
                                        // Set temp breakpoint at prologue end and continue
                                        const tmp_id = self.bp_manager.setTemporary(prologue_addr) catch
                                            return self.handleStop(step_result.signal);
                                        self.bp_manager.writeBreakpoint(tmp_id, &self.process) catch
                                            return self.handleStop(step_result.signal);
                                        self.process.continueExecution() catch
                                            return self.handleStop(step_result.signal);
                                        const result = try self.waitAndHandleStop();
                                        self.bp_manager.cleanupTemporary(&self.process);
                                        return result;
                                    }
                                }
                                // Already at prologue end or no prologue info
                                return self.handleStop(step_result.signal);
                            }

                            // Same function — check if we've reached a different source line
                            if (pre_line) |pl| {
                                const post_line = self.getLineForPC(post_regs.pc);
                                if (post_line != null and post_line.? != pl) {
                                    // Reached a new line — stop here
                                    return self.handleStop(step_result.signal);
                                }
                            } else {
                                // No pre_line info — stop after first step
                                return self.handleStop(step_result.signal);
                            }
                            // Same line, same function — continue single-stepping
                        },
                        else => return .{ .stop_reason = .step },
                    }
                }
                // Exhausted step limit — return current state
                const final_result = try self.process.waitForStop();
                return self.handleStop(final_result.signal);
            },
            .step_over => {
                // Read registers BEFORE stepping past breakpoint to capture
                // the original function/line context. This is critical because
                // stepPastBreakpoint single-steps the instruction, and if it's
                // a call, the PC will move into the callee.
                const original_regs = try self.process.readRegisters();

                // Step past watchpoint if needed
                if (self.stepping_past_wp) |wp_slot| {
                    try self.stepPastWatchpoint(wp_slot);
                    self.stepping_past_wp = null;
                }
                // Step past breakpoint if needed
                if (self.stepping_past_bp) |bp_addr| {
                    try self.stepPastBreakpoint(bp_addr);
                    self.stepping_past_bp = null;
                }
                // Instruction-level granularity: just single step
                if (options.granularity) |g| {
                    if (g == .instruction) {
                        self.is_single_stepping = true;
                        try self.process.singleStep();
                        const result = try self.waitAndHandleStop();
                        self.is_single_stepping = false;
                        return result;
                    }
                }
                // Frame-aware step_over: record frame identity before stepping,
                // then verify we're still in the same frame after each stop.
                // Uses function address range as primary check (always works),
                // with CFA or SP as secondary frame identity (handles same-function recursion).
                // This prevents entering callees when Go's SIGURG causes a resume
                // after the process has already entered a callee.
                const current_line = self.getLineForPC(original_regs.pc);

                // Frame identity: use CFA if available, else SP (always available from registers)
                const pre_cfa = self.computeCfa(original_regs);
                const pre_frame_id = pre_cfa orelse original_regs.sp;

                if (current_line != null and self.line_entries.len > 0) {
                    // Find current function range using original PC (before stepPastBreakpoint)
                    const func_info = self.findFunctionInfoForPC(original_regs.pc);
                    const func_low = if (func_info) |fi| fi.low_pc else 0;
                    const func_high = if (func_info) |fi| fi.high_pc else 0;

                    // Multi-BP strategy (like Delve): set breakpoints on ALL subsequent
                    // statement lines in the current function, not just the next line.
                    // This ensures we catch the correct stop point even if morestack
                    // or other runtime trampolines intervene.
                    var bp_targets: [32]u64 = undefined;
                    var bp_count: usize = 0;
                    if (func_low != 0 and func_high != 0) {
                        bp_count = self.findAllLineAddressesInRange(
                            original_regs.pc,
                            func_low,
                            func_high,
                            current_line.?,
                            &bp_targets,
                        );
                    }
                    // Fallback: if no multi-BP targets, use single next-line
                    if (bp_count == 0) {
                        if (self.findNextLineAddress(original_regs.pc)) |addr| {
                            bp_targets[0] = addr;
                            bp_count = 1;
                        }
                    }

                    if (bp_count > 0) {
                        // Set temp BPs at all target addresses
                        var any_bp_set = false;
                        for (bp_targets[0..bp_count]) |target_addr| {
                            const tmp_id = self.bp_manager.setTemporary(target_addr) catch continue;
                            self.bp_manager.writeBreakpoint(tmp_id, &self.process) catch continue;
                            any_bp_set = true;
                        }
                        if (!any_bp_set) {
                            // Can't set any breakpoints — fall back to single step
                            try self.process.singleStep();
                            return self.waitAndHandleStop();
                        }
                        // Safety-net BP at return address (use original regs for correct frame)
                        const ret_addr = self.getReturnAddress(original_regs) catch null;
                        if (ret_addr) |ra| {
                            const ret_id = self.bp_manager.setTemporary(ra) catch null;
                            if (ret_id) |rid| {
                                self.bp_manager.writeBreakpoint(rid, &self.process) catch {};
                            }
                        }

                        // Frame-checked stepping loop
                        var step_attempts: u32 = 0;
                        const max_step_attempts: u32 = 50;
                        while (step_attempts < max_step_attempts) : (step_attempts += 1) {
                            try self.process.continueExecution();
                            const result = try self.waitAndHandleStop();
                            self.bp_manager.cleanupTemporary(&self.process);

                            // If process exited or hit exception, return immediately
                            if (result.stop_reason == .exited or result.stop_reason == .exception) {
                                return result;
                            }

                            const post_regs = self.process.readRegisters() catch return result;
                            const post_line = self.getLineForPC(post_regs.pc);

                            // PRIMARY CHECK: Is PC within the original function?
                            const in_original_func = if (func_low != 0 and func_high != 0)
                                (post_regs.pc >= func_low and post_regs.pc < func_high)
                            else
                                true;

                            if (in_original_func) {
                                if (post_line != null and post_line.? != current_line.?) {
                                    // Verify frame identity (handles recursion)
                                    const post_cfa = self.computeCfa(post_regs);
                                    const post_frame_id = post_cfa orelse post_regs.sp;
                                    if (post_frame_id == pre_frame_id) {
                                        return result; // Same frame, different line — success!
                                    }
                                } else {
                                    // Same line — re-set all BPs and continue
                                    for (bp_targets[0..bp_count]) |target_addr| {
                                        const re_id = self.bp_manager.setTemporary(target_addr) catch continue;
                                        self.bp_manager.writeBreakpoint(re_id, &self.process) catch continue;
                                    }
                                    if (ret_addr) |ra| {
                                        const re_ret = self.bp_manager.setTemporary(ra) catch null;
                                        if (re_ret) |rid| {
                                            self.bp_manager.writeBreakpoint(rid, &self.process) catch {};
                                        }
                                    }
                                    continue;
                                }
                            }

                            // We left the original function. Check if it's a runtime trampoline.
                            const post_func_name = if (self.functions.len > 0)
                                unwind.findFunctionForPC(self.functions, post_regs.pc)
                            else
                                "";
                            if (isRuntimeTrampoline(post_func_name)) {
                                // In morestack/gogo/etc — re-set all BPs and continue.
                                // After stack growth completes, execution will return to
                                // our function (or its callee), hitting one of our BPs.
                                for (bp_targets[0..bp_count]) |target_addr| {
                                    const re_id = self.bp_manager.setTemporary(target_addr) catch continue;
                                    self.bp_manager.writeBreakpoint(re_id, &self.process) catch continue;
                                }
                                if (ret_addr) |ra| {
                                    const re_ret = self.bp_manager.setTemporary(ra) catch null;
                                    if (re_ret) |rid| {
                                        self.bp_manager.writeBreakpoint(rid, &self.process) catch {};
                                    }
                                }
                                continue;
                            }

                            // Not a trampoline — we're in a real callee or returned to caller.
                            const post_cfa = self.computeCfa(post_regs);
                            const post_frame_id = post_cfa orelse post_regs.sp;

                            if (post_frame_id > pre_frame_id) {
                                // Returned to caller — acceptable
                                return result;
                            }

                            // Entered a callee — set BP at return address and continue
                            const callee_ret = self.getReturnAddress(post_regs) catch null;
                            if (callee_ret) |cr| {
                                const cr_id = self.bp_manager.setTemporary(cr) catch return result;
                                self.bp_manager.writeBreakpoint(cr_id, &self.process) catch return result;
                                // Also re-set our function BPs in case we return through morestack
                                for (bp_targets[0..bp_count]) |target_addr| {
                                    const re_id = self.bp_manager.setTemporary(target_addr) catch continue;
                                    self.bp_manager.writeBreakpoint(re_id, &self.process) catch continue;
                                }
                                continue;
                            }
                            return result;
                        }
                        // Exhausted attempts
                        return .{ .stop_reason = .step };
                    }
                }
                // Fallback: single step
                self.is_single_stepping = true;
                try self.process.singleStep();
            },
            .step_out => {
                if (self.stepping_past_wp) |wp_slot| {
                    try self.stepPastWatchpoint(wp_slot);
                    self.stepping_past_wp = null;
                }
                if (self.stepping_past_bp) |bp_addr| {
                    try self.stepPastBreakpoint(bp_addr);
                    self.stepping_past_bp = null;
                }
                // Read return address from stack frame
                const regs = try self.process.readRegisters();
                const ret_addr = self.getReturnAddress(regs) catch null;
                if (ret_addr) |addr| {
                    // Phase 1: Set temporary breakpoint at return address, then continue
                    const tmp_id = try self.bp_manager.setTemporary(addr);
                    self.bp_manager.writeBreakpoint(tmp_id, &self.process) catch {
                        try self.process.continueExecution();
                        return self.waitAndHandleStop();
                    };
                    try self.process.continueExecution();
                    const phase1_result = try self.waitAndHandleStop();
                    self.bp_manager.cleanupTemporary(&self.process);

                    // Phase 2: Advance past the return value assignment to the next source line.
                    // The return address points to the instruction right after CALL (typically
                    // a store that writes the return value to a local). We need to execute past
                    // it so the variable reflects the returned value.
                    const phase1_reason = phase1_result.stop_reason;
                    if (phase1_reason != .breakpoint and phase1_reason != .step) {
                        return phase1_result;
                    }
                    // Clear stepping_past_bp since the temp BP was already cleaned up
                    self.stepping_past_bp = null;
                    const phase2_regs = try self.process.readRegisters();
                    if (self.findNextLineAddress(phase2_regs.pc)) |next_addr| {
                        const tmp2_id = try self.bp_manager.setTemporary(next_addr);
                        self.bp_manager.writeBreakpoint(tmp2_id, &self.process) catch {
                            return phase1_result;
                        };
                        try self.process.continueExecution();
                        const phase2_result = try self.waitAndHandleStop();
                        self.bp_manager.cleanupTemporary(&self.process);
                        return phase2_result;
                    }
                    return phase1_result;
                }
                // Fallback: continue without breakpoint
                try self.process.continueExecution();
            },
            .restart => {
                self.process.kill() catch {};
                if (self.program_path) |path| {
                    const old_slide = self.aslr_slide;
                    self.process.spawn(self.allocator, path, &.{}) catch {
                        return .{ .stop_reason = .exception };
                    };
                    // Reload debug info fresh so ASLR slide is applied to un-slided data
                    self.aslr_slide = 0;
                    self.loadDebugInfo(path) catch {};
                    self.applyAslrSlide() catch {};
                    // Adjust existing breakpoint addresses for new ASLR slide
                    const slide_diff = self.aslr_slide - old_slide;
                    if (slide_diff != 0) {
                        for (self.bp_manager.breakpoints.items) |*bp| {
                            if (bp.enabled) {
                                if (slide_diff > 0) {
                                    bp.address +%= @intCast(@as(u64, @intCast(slide_diff)));
                                } else {
                                    bp.address -%= @intCast(@as(u64, @intCast(-slide_diff)));
                                }
                            }
                        }
                    }
                    self.rearmAllBreakpoints();
                    self.stepping_past_bp = null;
                    self.stepping_past_wp = null;
                    self.hw_watchpoints = [_]HardwareWatchpoint{.{}} ** 4;
                    return .{ .stop_reason = .entry };
                }
                return .{ .stop_reason = .exception };
            },
            .pause => {
                // Send SIGSTOP to pause a running process
                if (self.process.pid) |pid| {
                    const posix = std.posix;
                    posix.kill(pid, posix.SIG.STOP) catch {};
                }
                const result = try self.process.waitForStop();
                return switch (result.status) {
                    .stopped => .{ .stop_reason = .pause },
                    .exited => .{ .stop_reason = if (result.exit_code == 0) .exited else .exception, .exit_code = result.exit_code },
                    else => .{ .stop_reason = .pause },
                };
            },
            .reverse_continue, .step_back => {
                // Reverse debugging not supported by native DWARF engine
                return error.NotSupported;
            },
        }

        // Wait and handle stop — with transparent resume for conditional breakpoints
        const stop_state = try self.waitAndHandleStop();
        self.is_single_stepping = false;
        return stop_state;
    }

    /// Wait for the process to stop, then evaluate breakpoint conditions.
    /// If shouldStop() returns false, transparently resume and wait again.
    fn waitAndHandleStop(self: *DwarfEngine) !StopState {
        // Limit transparent resumes to avoid infinite loops
        var resume_count: u32 = 0;
        const max_resumes: u32 = 10000;

        // Accumulate log point messages during transparent resumes
        var collected_logs = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            // If we exit without attaching logs to state, free them
            for (collected_logs.items) |msg| self.allocator.free(msg);
            collected_logs.deinit(self.allocator);
        }

        while (resume_count < max_resumes) {
            const result = try self.process.waitForStop();
            switch (result.status) {
                .stopped => {
                    var state = self.handleStop(result.signal);
                    if (state.should_resume) {
                        // Collect any log point messages before resuming
                        for (state.log_messages) |msg| {
                            collected_logs.append(self.allocator, msg) catch {};
                        }
                        // Free the temporary slice (but not the strings, now owned by collected_logs)
                        if (state.log_messages.len > 0) {
                            self.allocator.free(state.log_messages);
                        }

                        // Condition not met, log point, or non-fatal signal — transparently resume
                        if (self.stepping_past_wp) |wp_slot| {
                            self.stepPastWatchpoint(wp_slot) catch {};
                            self.stepping_past_wp = null;
                        }
                        if (self.stepping_past_bp) |bp_addr| {
                            self.stepPastBreakpoint(bp_addr) catch {};
                            self.stepping_past_bp = null;
                        }
                        // Re-issue the appropriate operation: single-step or continue
                        if (self.is_single_stepping) {
                            self.process.singleStep() catch {};
                        } else {
                            self.process.continueExecution() catch {};
                        }
                        resume_count += 1;
                        continue;
                    }

                    // Attach accumulated log messages to final state
                    if (collected_logs.items.len > 0) {
                        state.log_messages = collected_logs.toOwnedSlice(self.allocator) catch &.{};
                    }
                    return state;
                },
                .exited => {
                    const reason: types.StopReason = if (result.exit_code == 0) .exited else .exception;
                    var state: StopState = .{ .stop_reason = reason, .exit_code = result.exit_code };
                    if (collected_logs.items.len > 0) {
                        state.log_messages = collected_logs.toOwnedSlice(self.allocator) catch &.{};
                    }
                    return state;
                },
                else => return .{ .stop_reason = .step },
            }
        }

        // Safety: if we've hit the resume limit, stop and report
        return .{ .stop_reason = .step };
    }

    /// Get the source line number for a given PC address.
    /// Uses binary search (line_entries are sorted by address during loadDebugInfo).
    fn getLineForPC(self: *DwarfEngine, pc: u64) ?u32 {
        if (self.line_entries.len == 0) return null;
        // Binary search: find rightmost entry with address <= pc
        var lo: usize = 0;
        var hi: usize = self.line_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_entries[mid].address <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Walk back to find non-end_sequence entry
        var i = lo;
        while (i > 0) {
            i -= 1;
            if (!self.line_entries[i].end_sequence) {
                return self.line_entries[i].line;
            }
        }
        return null;
    }

    /// Find the address of the next source line after the given PC.
    /// Uses binary search to find current position, then scans forward.
    fn findNextLineAddress(self: *DwarfEngine, pc: u64) ?u64 {
        if (self.line_entries.len == 0) return null;
        const current_line = self.getLineForPC(pc) orelse return null;
        // Binary search: find first entry with address > pc
        var lo: usize = 0;
        var hi: usize = self.line_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_entries[mid].address <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Scan forward from lo for next statement with a different line
        for (self.line_entries[lo..]) |entry| {
            if (entry.end_sequence) continue;
            if (!entry.is_stmt) continue;
            if (entry.line != current_line) {
                return entry.address;
            }
        }
        return null;
    }

    /// Like findNextLineAddress but constrained to a function's address range.
    /// Returns the address of the next source line after `pc` that is within [func_low, func_high).
    fn findNextLineAddressInRange(self: *DwarfEngine, pc: u64, func_low: u64, func_high: u64) ?u64 {
        if (self.line_entries.len == 0) return null;
        const current_line = self.getLineForPC(pc) orelse return null;
        // Binary search: find first entry with address > pc
        var lo: usize = 0;
        var hi: usize = self.line_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_entries[mid].address <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Scan forward from lo for next statement with a different line, within function range
        for (self.line_entries[lo..]) |entry| {
            if (func_high > 0 and entry.address >= func_high) break;
            if (entry.end_sequence) continue;
            if (!entry.is_stmt) continue;
            if (entry.address < func_low) continue;
            if (entry.line != current_line) {
                return entry.address;
            }
        }
        return null;
    }

    /// Find ALL statement line addresses within a function range that are on lines
    /// different from `current_line`. Used for multi-BP step_over (like Delve's strategy).
    /// Returns the number of addresses written into `buf`.
    fn findAllLineAddressesInRange(
        self: *DwarfEngine,
        pc: u64,
        func_low: u64,
        func_high: u64,
        current_line: u32,
        buf: []u64,
    ) usize {
        if (self.line_entries.len == 0) return 0;
        // Binary search: find first entry with address > pc
        var lo: usize = 0;
        var hi: usize = self.line_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_entries[mid].address <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        var count: usize = 0;
        var last_line: u32 = current_line;
        for (self.line_entries[lo..]) |entry| {
            if (func_high > 0 and entry.address >= func_high) break;
            if (entry.end_sequence) continue;
            if (!entry.is_stmt) continue;
            if (entry.address < func_low) continue;
            if (entry.line != current_line and entry.line != last_line) {
                if (count >= buf.len) break;
                buf[count] = entry.address;
                count += 1;
                last_line = entry.line;
            }
        }
        return count;
    }

    /// Find the FunctionInfo (with address range) for a PC. Returns null if no function contains pc.
    fn findFunctionInfoForPC(self: *DwarfEngine, pc: u64) ?parser.FunctionInfo {
        if (self.functions.len == 0) return null;
        // Binary search: find rightmost function with low_pc <= pc
        var lo: usize = 0;
        var hi: usize = self.functions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.functions[mid].low_pc <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        const f = self.functions[lo - 1];
        if (pc >= f.low_pc and (f.high_pc == 0 or pc < f.high_pc)) {
            return f;
        }
        return null;
    }

    /// Find the nearest DWARF line address <= dwarf_pc using binary search.
    /// Converts between runtime and DWARF address spaces via aslr_slide.
    fn findNearestDwarfLineAddress(self: *const DwarfEngine, dwarf_pc: u64) u64 {
        if (self.line_entries.len == 0) return 0;
        // Convert DWARF PC to runtime PC for comparison against sorted line_entries
        const runtime_pc = if (self.aslr_slide >= 0)
            dwarf_pc +% @as(u64, @intCast(self.aslr_slide))
        else
            dwarf_pc -% @as(u64, @intCast(-self.aslr_slide));
        // Binary search: find rightmost entry with address <= runtime_pc
        var lo: usize = 0;
        var hi: usize = self.line_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_entries[mid].address <= runtime_pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Walk back to find non-end_sequence entry
        var i = lo;
        while (i > 0) {
            i -= 1;
            if (!self.line_entries[i].end_sequence) {
                // Convert back to DWARF address space
                return if (self.aslr_slide >= 0)
                    self.line_entries[i].address -% @as(u64, @intCast(self.aslr_slide))
                else
                    self.line_entries[i].address +% @as(u64, @intCast(-self.aslr_slide));
            }
        }
        return 0;
    }

    /// Find the prologue end address for a function containing the given PC.
    /// Returns the first line entry with `prologue_end == true` in the function's range.
    /// Falls back to the first `is_stmt` entry if no prologue_end marker exists.
    fn findPrologueEndAddress(self: *DwarfEngine, pc: u64) ?u64 {
        if (self.line_entries.len == 0 or self.functions.len == 0) return null;

        // Binary search: find the function containing this PC
        var func_start: u64 = 0;
        var func_end: u64 = 0;
        var lo: usize = 0;
        var hi: usize = self.functions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.functions[mid].low_pc <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo > 0) {
            const f = self.functions[lo - 1];
            if (pc >= f.low_pc and (f.high_pc == 0 or pc < f.high_pc)) {
                func_start = f.low_pc;
                func_end = f.high_pc;
            }
        }
        if (func_start == 0 and func_end == 0) return null;

        // Binary search line_entries for the first entry at or after func_start
        lo = 0;
        hi = self.line_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_entries[mid].address < func_start) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        // Scan forward within the function's range
        var first_stmt: ?u64 = null;
        for (self.line_entries[lo..]) |entry| {
            if (func_end > 0 and entry.address >= func_end) break;
            if (entry.end_sequence) continue;

            if (entry.prologue_end) {
                return entry.address;
            }
            if (entry.is_stmt and first_stmt == null and entry.address >= func_start) {
                first_stmt = entry.address;
            }
        }

        // Fall back to first is_stmt entry in the function
        return first_stmt;
    }

    /// Read the return address from the current stack frame.
    fn getReturnAddress(self: *DwarfEngine, regs: process_mod.RegisterState) !?u64 {
        const is_arm = builtin.cpu.arch == .aarch64;
        if (is_arm) {
            // On ARM64, return address is in LR (x30) or saved at [FP+8]
            const lr = regs.gprs[30];
            if (lr != 0) return lr;
            // Try reading from stack
            if (regs.fp != 0) {
                const mem = self.process.readMemory(regs.fp + 8, 8, self.allocator) catch return null;
                defer self.allocator.free(mem);
                return std.mem.readInt(u64, mem[0..8], .little);
            }
            return null;
        } else {
            // On x86_64, return address is at [RBP+8]
            if (regs.fp == 0) return null;
            const mem = self.process.readMemory(regs.fp + 8, 8, self.allocator) catch return null;
            defer self.allocator.free(mem);
            return std.mem.readInt(u64, mem[0..8], .little);
        }
    }

    fn handleStop(self: *DwarfEngine, signal: i32) StopState {
        const SIGTRAP = 5;
        if (signal != SIGTRAP) {
            // Check if this signal matches an exception breakpoint
            if (signal > 0 and signal < 32 and self.exception_signals[@intCast(signal)]) {
                return .{
                    .stop_reason = .exception,
                    .exception = .{
                        .@"type" = signalName(@intCast(signal)),
                        .message = "Signal received",
                    },
                };
            }
            // Fatal signals always stop (SIGILL, SIGABRT, SIGBUS, SIGFPE, SIGSEGV)
            if (signal > 0 and signal < 32 and isFatalSignal(@intCast(signal))) {
                return .{
                    .stop_reason = .exception,
                    .exception = .{
                        .@"type" = signalName(@intCast(signal)),
                        .message = "Fatal signal received",
                    },
                };
            }
            // Non-fatal, non-configured signal (e.g. SIGURG from Go runtime) — resume
            return .{ .stop_reason = .step, .should_resume = true };
        }

        // Read PC to check if we hit a breakpoint
        const regs = self.process.readRegisters() catch {
            return .{ .stop_reason = .step };
        };

        // On x86_64, after INT3, RIP points past the 0xCC byte, so bp address is RIP-1
        // On ARM64, after BRK, PC points at the BRK instruction itself
        const is_arm = builtin.cpu.arch == .aarch64;
        const bp_addr = if (is_arm) regs.pc else regs.pc - 1;

        if (self.bp_manager.findByAddress(bp_addr)) |bp| {
            // Clean up any previous condition context
            if (self.condition_context) |*ctx| {
                ctx.deinit();
                self.condition_context = null;
            }

            // Build condition evaluator from engine's DWARF state
            const evaluator = self.buildConditionEvaluator(regs);

            // Evaluate whether we should actually stop at this breakpoint
            const should_stop = self.bp_manager.shouldStop(bp, evaluator);

            // Clean up condition context after evaluation
            if (self.condition_context) |*ctx| {
                ctx.deinit();
                self.condition_context = null;
            }

            // Rewind PC to the breakpoint address (before INT3)
            if (!is_arm) {
                var new_regs = regs;
                new_regs.pc = bp_addr;
                self.process.writeRegisters(new_regs) catch {};
            }

            // Mark that we need to step past this breakpoint on next continue
            self.stepping_past_bp = bp_addr;

            if (!should_stop) {
                // Condition not met or log point — signal transparent resume
                // If this is a log point, evaluate the template
                const evaluated_msg: ?[]const u8 = if (bp.log_message) |msg|
                    self.evaluateLogMessage(msg, regs)
                else
                    null;

                return .{
                    .stop_reason = .breakpoint,
                    .should_resume = true,
                    .log_messages = if (evaluated_msg) |m| blk: {
                        const slice = self.allocator.alloc([]const u8, 1) catch break :blk &.{};
                        slice[0] = m;
                        break :blk slice;
                    } else &.{},
                };
            }

            // Build stack trace
            const stack_trace = self.buildStackTrace(regs) catch &.{};

            // Cache stack trace for per-frame inspection
            self.cacheStackTrace(stack_trace);

            // Build locals
            const locals = self.buildLocals(regs) catch &.{};

            // Resolve function name for location
            const func_name = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, regs.pc) else "";

            // Use .step reason if a step operation landed on a breakpoint
            const reason: types.StopReason = if (self.step_in_progress) .step else .breakpoint;

            // Build location: prefer breakpoint info, fall back to PC resolution
            const loc: ?types.SourceLocation = if (bp.file.len > 0 and bp.line > 0)
                .{ .file = bp.file, .line = bp.line, .function = func_name }
            else if (self.line_entries.len > 0 and self.file_entries.len > 0) blk: {
                break :blk if (parser.resolveAddress(self.line_entries, self.file_entries, bp_addr)) |r|
                    types.SourceLocation{ .file = r.file, .line = r.line, .function = func_name }
                else if (parser.resolveAddress(self.line_entries, self.file_entries, bp_addr -| 1)) |r|
                    types.SourceLocation{ .file = r.file, .line = r.line, .function = func_name }
                else if (stack_trace.len > 0 and stack_trace[0].source.len > 0)
                    types.SourceLocation{ .file = stack_trace[0].source, .line = stack_trace[0].line, .function = func_name }
                else
                    null;
            } else null;

            return .{
                .stop_reason = reason,
                .location = loc,
                .stack_trace = stack_trace,
                .locals = locals,
            };
        }

        // Check for hardware watchpoint hit:
        // If we got SIGTRAP, no software breakpoint at this address, and we're
        // not in a single-step operation, check if any hardware watchpoints are active.
        // On ARM64, watchpoint traps halt BEFORE the faulting instruction executes.
        if (!self.is_single_stepping) {
            for (&self.hw_watchpoints, 0..) |*wp, slot_idx| {
                if (!wp.active) continue;

                // Set step-past state so next resume will step past the watchpoint
                self.stepping_past_wp = @intCast(slot_idx);

                // Build stack trace and locals for the stop
                const wp_stack_trace = self.buildStackTrace(regs) catch &.{};
                self.cacheStackTrace(wp_stack_trace);
                const wp_locals = self.buildLocals(regs) catch &.{};
                const wp_func_name = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, regs.pc) else "";
                const wp_loc = if (self.line_entries.len > 0 and self.file_entries.len > 0)
                    parser.resolveAddress(self.line_entries, self.file_entries, regs.pc)
                else
                    null;

                const wp_bp_ids: []const u32 = if (self.allocator.alloc(u32, 1)) |ids| blk: {
                    ids[0] = wp.id;
                    break :blk ids;
                } else |_| &.{};

                return .{
                    .stop_reason = .data_breakpoint,
                    .hit_breakpoint_ids = wp_bp_ids,
                    .location = if (wp_loc) |l| .{
                        .file = l.file,
                        .line = l.line,
                        .function = wp_func_name,
                    } else null,
                    .stack_trace = wp_stack_trace,
                    .locals = wp_locals,
                };
            }
        }

        // For step stops, also provide stack trace and locals
        const stack_trace = self.buildStackTrace(regs) catch &.{};

        // Cache stack trace for per-frame inspection
        self.cacheStackTrace(stack_trace);

        const locals = self.buildLocals(regs) catch &.{};

        // Resolve function name for location
        const func_name = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, regs.pc) else "";

        // Resolve location from PC
        const loc = if (self.line_entries.len > 0 and self.file_entries.len > 0)
            parser.resolveAddress(self.line_entries, self.file_entries, regs.pc)
        else
            null;

        return .{
            .stop_reason = .step,
            .location = if (loc) |l| .{
                .file = l.file,
                .line = l.line,
                .function = func_name,
            } else if (stack_trace.len > 0 and stack_trace[0].source.len > 0 and stack_trace[0].line > 0) .{
                .file = stack_trace[0].source,
                .line = stack_trace[0].line,
                .function = func_name,
            } else if (func_name.len > 0 and !std.mem.eql(u8, func_name, "<unknown>")) .{
                .file = "",
                .line = 0,
                .function = func_name,
            } else null,
            .stack_trace = stack_trace,
            .locals = locals,
        };
    }

    fn buildStackTrace(self: *DwarfEngine, regs: process_mod.RegisterState) ![]const types.StackFrame {
        if (self.functions.len == 0) return &.{};

        const fp_frames = try unwind.unwindStackFP(
            regs.pc,
            regs.fp,
            self.functions,
            self.line_entries,
            self.file_entries,
            &self.process,
            self.allocator,
            50,
        );

        // Skip CFA unwinding if FP trace looks complete (reached main/_start)
        // This avoids the overhead of CFA unwinding when FP unwinding already produced a full trace.
        var unwind_frames = fp_frames;
        const fp_complete = fp_frames.len >= 2 and blk: {
            const last_name = fp_frames[fp_frames.len - 1].function_name;
            break :blk std.mem.eql(u8, last_name, "main") or std.mem.eql(u8, last_name, "_start");
        };
        if (!fp_complete) {
            if (self.resolveFrameData()) |eh_frame_data| {
                var cfa_ctx = CfaReaderCtx{
                    .regs = regs,
                    .process = &self.process,
                    .allocator = self.allocator,
                };
                const cfa_frames = unwind.unwindStackCfa(
                    eh_frame_data,
                    regs.pc,
                    regs.sp,
                    self.functions,
                    self.line_entries,
                    self.file_entries,
                    @ptrCast(&cfa_ctx),
                    &CfaReaderCtx.regReader,
                    &CfaReaderCtx.memReader,
                    self.allocator,
                    50,
                    if (self.eh_frame_index) |*idx| idx else null,
                    if (self.cie_cache) |*cc| cc else null,
                    self.is_debug_frame,
                ) catch fp_frames;

                // Use CFA result only if it's better than FP result
                if (cfa_frames.len > fp_frames.len) {
                    self.allocator.free(fp_frames);
                    unwind_frames = cfa_frames;
                } else {
                    if (cfa_frames.ptr != fp_frames.ptr) {
                        self.allocator.free(cfa_frames);
                    }
                }
            }
        }
        defer self.allocator.free(unwind_frames);

        if (unwind_frames.len == 0) return &.{};

        // Build frames, inserting virtual inlined frames where applicable
        var frame_list = std.ArrayListUnmanaged(types.StackFrame).empty;
        errdefer frame_list.deinit(self.allocator);

        var next_id: u32 = 0;
        for (unwind_frames) |uf| {
            // Check if this frame's PC falls within any inlined subroutine
            if (self.inlined_subs.len > 0) {
                const inlined = parser.findInlinedSubroutines(
                    self.inlined_subs,
                    uf.address,
                    self.allocator,
                ) catch &.{};
                defer if (inlined.len > 0) self.allocator.free(inlined);

                // Insert virtual frames for each inlined subroutine (innermost first)
                for (inlined) |isub| {
                    const source_name = if (isub.call_file > 0 and self.file_entries.len > 0)
                        getFileName(self.file_entries, isub.call_file)
                    else
                        uf.file;
                    try frame_list.append(self.allocator, .{
                        .id = next_id,
                        .name = isub.name orelse "[inlined]",
                        .source = source_name,
                        .line = isub.call_line,
                        .column = isub.call_column,
                    });
                    next_id += 1;
                }
            }

            // Add the physical frame (SP is set to 0 initially; corrected below via CFA chain)
            try frame_list.append(self.allocator, .{
                .id = next_id,
                .name = uf.function_name,
                .source = uf.file,
                .line = uf.line,
                .address = uf.address,
                .fp = uf.fp,
                .sp = if (uf.sp != 0) uf.sp else 0,
            });
            next_id += 1;
        }

        // Compute correct SP for each physical frame using CFA chain.
        // Frame 0's SP comes from actual registers. Frame N's SP = CFA of frame N-1,
        // because on ARM64 the caller's SP at the call site equals the callee's CFA.
        {
            var prev_cfa: ?u64 = null;
            var is_first_physical = true;
            for (frame_list.items) |*frame| {
                if (frame.fp == 0 and frame.address == 0) continue; // skip inlined/virtual frames

                if (is_first_physical) {
                    frame.sp = regs.sp;
                    prev_cfa = self.computeCfa(regs);
                    is_first_physical = false;
                } else {
                    // SP for this frame = CFA of the previous (callee) frame
                    if (prev_cfa) |sp| {
                        frame.sp = sp;
                    } else if (frame.fp != 0) {
                        frame.sp = frame.fp; // last resort fallback
                    }
                    // Compute CFA for this frame to propagate to the next
                    var frame_regs = regs;
                    frame_regs.fp = frame.fp;
                    frame_regs.pc = frame.address;
                    frame_regs.sp = frame.sp;
                    if (builtin.cpu.arch == .aarch64) {
                        frame_regs.gprs[29] = frame.fp;
                        frame_regs.gprs[31] = frame.sp;
                    } else if (builtin.cpu.arch == .x86_64) {
                        frame_regs.gprs[6] = frame.fp;
                        frame_regs.gprs[7] = frame.sp;
                    }
                    prev_cfa = self.computeCfa(frame_regs);
                }
            }
        }

        return try frame_list.toOwnedSlice(self.allocator);
    }

    /// Get a file name from file entries by 0-based index.
    fn getFileName(files: []const parser.FileEntry, index: u32) []const u8 {
        if (index < files.len) {
            return files[index].name;
        }
        return "<unknown>";
    }

    /// Helper to resolve debug section data from either Mach-O or ELF binary.
    const DebugData = struct {
        info_data: []const u8,
        abbrev_data: []const u8,
        str_data: ?[]const u8,
        str_offsets_data: ?[]const u8,
        addr_data: ?[]const u8,
        ranges_data: ?[]const u8,
        rnglists_data: ?[]const u8,
        loc_data: ?[]const u8,
        loclists_data: ?[]const u8,
    };

    /// Find the CU start position for a given DWARF PC using the CU index.
    fn cuHintForPC(self: *const DwarfEngine, dwarf_pc: u64) ?usize {
        return parser.findCuForPC(self.cu_index, dwarf_pc);
    }

    fn resolveDebugData(self: *DwarfEngine) ?DebugData {
        // Try Mach-O binaries (dSYM first, then main)
        if (self.dsym_binary) |*dsym| {
            if (self.resolveDebugDataFromMacho(dsym)) |d| return d;
        }
        if (self.binary) |*bin| {
            if (self.resolveDebugDataFromMacho(bin)) |d| return d;
        }
        // Try ELF binary
        if (self.elf_binary) |*elf| {
            return self.resolveDebugDataFromElf(elf);
        }
        return null;
    }

    fn resolveDebugDataFromMacho(self: *DwarfEngine, bin: *binary_macho.MachoBinary) ?DebugData {
        const info_section = bin.sections.debug_info orelse return null;
        const abbrev_section = bin.sections.debug_abbrev orelse return null;
        const info_data = (bin.getSectionDataAlloc(self.allocator, info_section) catch null) orelse bin.getSectionData(info_section) orelse return null;
        const abbrev_data = (bin.getSectionDataAlloc(self.allocator, abbrev_section) catch null) orelse bin.getSectionData(abbrev_section) orelse return null;
        return .{
            .info_data = info_data,
            .abbrev_data = abbrev_data,
            .str_data = if (bin.sections.debug_str) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
            .str_offsets_data = if (bin.sections.debug_str_offsets) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
            .addr_data = if (bin.sections.debug_addr) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
            .ranges_data = if (bin.sections.debug_ranges) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
            .rnglists_data = if (bin.sections.debug_rnglists) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
            .loc_data = if (bin.sections.debug_loc) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
            .loclists_data = if (bin.sections.debug_loclists) |s| (bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s) else null,
        };
    }

    fn resolveDebugDataFromElf(self: *DwarfEngine, elf: *binary_elf.ElfBinary) ?DebugData {
        const info_section = elf.sections.debug_info orelse return null;
        const abbrev_section = elf.sections.debug_abbrev orelse return null;
        const info_data = (elf.getSectionDataAlloc(self.allocator, info_section) catch null) orelse elf.getSectionData(info_section) orelse return null;
        const abbrev_data = (elf.getSectionDataAlloc(self.allocator, abbrev_section) catch null) orelse elf.getSectionData(abbrev_section) orelse return null;
        return .{
            .info_data = info_data,
            .abbrev_data = abbrev_data,
            .str_data = if (elf.sections.debug_str) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .str_offsets_data = if (elf.sections.debug_str_offsets) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .addr_data = if (elf.sections.debug_addr) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .ranges_data = if (elf.sections.debug_ranges) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .rnglists_data = if (elf.sections.debug_rnglists) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .loc_data = if (elf.sections.debug_loc) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
            .loclists_data = if (elf.sections.debug_loclists) |s| (elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s) else null,
        };
    }

    /// Resolve .eh_frame or .debug_frame section data from available binaries.
    /// Tries .eh_frame first, then falls back to .debug_frame (used by Go binaries).
    /// Sets self.is_debug_frame accordingly.
    fn resolveFrameData(self: *DwarfEngine) ?[]const u8 {
        // Try .eh_frame first
        if (self.dsym_binary) |*dsym| {
            if (dsym.sections.eh_frame) |s| {
                if ((dsym.getSectionDataAlloc(self.allocator, s) catch null) orelse dsym.getSectionData(s)) |d| {
                    self.is_debug_frame = false;
                    return d;
                }
            }
        }
        if (self.binary) |*bin| {
            if (bin.sections.eh_frame) |s| {
                if ((bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s)) |d| {
                    self.is_debug_frame = false;
                    return d;
                }
            }
        }
        if (self.elf_binary) |*elf| {
            if (elf.sections.eh_frame) |s| {
                if ((elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s)) |d| {
                    self.is_debug_frame = false;
                    return d;
                }
            }
        }
        // Fall back to .debug_frame
        if (self.dsym_binary) |*dsym| {
            if (dsym.sections.debug_frame) |s| {
                if ((dsym.getSectionDataAlloc(self.allocator, s) catch null) orelse dsym.getSectionData(s)) |d| {
                    self.is_debug_frame = true;
                    return d;
                }
            }
        }
        if (self.binary) |*bin| {
            if (bin.sections.debug_frame) |s| {
                if ((bin.getSectionDataAlloc(self.allocator, s) catch null) orelse bin.getSectionData(s)) |d| {
                    self.is_debug_frame = true;
                    return d;
                }
            }
        }
        if (self.elf_binary) |*elf| {
            if (elf.sections.debug_frame) |s| {
                if ((elf.getSectionDataAlloc(self.allocator, s) catch null) orelse elf.getSectionData(s)) |d| {
                    self.is_debug_frame = true;
                    return d;
                }
            }
        }
        return null;
    }

    /// Context for CFA register/memory reader callbacks.
    /// Holds a snapshot of register state and a reference to the process
    /// so that plain (non-capturing) function pointers can access them.
    const CfaReaderCtx = struct {
        regs: process_mod.RegisterState,
        process: *ProcessControl,
        allocator: std.mem.Allocator,

        fn regReader(ctx_opaque: *anyopaque, reg: u64) ?u64 {
            const self: *CfaReaderCtx = @ptrCast(@alignCast(ctx_opaque));
            // DWARF register mapping (x86_64):
            //   0-15 = GPRs (rax, rdx, rcx, rbx, rsi, rdi, rbp, rsp, r8-r15)
            //   16 = return address (rip)
            // DWARF register mapping (aarch64):
            //   0-28 = x0-x28
            //   29 = fp (x29), 30 = lr (x30), 31 = sp
            if (builtin.cpu.arch == .x86_64) {
                return switch (reg) {
                    0...15 => self.regs.gprs[reg],
                    16 => self.regs.pc, // RIP
                    else => null,
                };
            } else if (builtin.cpu.arch == .aarch64) {
                return switch (reg) {
                    0...28 => self.regs.gprs[reg],
                    29 => self.regs.fp, // x29
                    30 => self.regs.gprs[30], // lr (x30)
                    31 => self.regs.sp,
                    else => null,
                };
            }
            return null;
        }

        fn memReader(ctx_opaque: *anyopaque, addr: u64, size: usize) ?u64 {
            const self: *CfaReaderCtx = @ptrCast(@alignCast(ctx_opaque));
            const data = self.process.readMemory(addr, size, self.allocator) catch return null;
            defer self.allocator.free(data);
            if (data.len < 8) return null;
            return std.mem.readInt(u64, data[0..8], .little);
        }
    };

    /// Compute the Canonical Frame Address from .eh_frame/.debug_frame.
    /// Uses the existing unwind infrastructure (EhFrameIndex, CieCache) for O(log n) lookup.
    fn computeCfa(self: *DwarfEngine, regs: process_mod.RegisterState) ?u64 {
        const eh_frame_data = self.resolveFrameData() orelse return null;
        // For .debug_frame, FDE addresses are absolute DWARF addresses.
        // Convert runtime PC to DWARF space for correct FDE lookup and CFA execution.
        const target_pc: u64 = if (self.is_debug_frame and self.aslr_slide != 0) blk: {
            break :blk if (self.aslr_slide >= 0)
                regs.pc -% @as(u64, @intCast(self.aslr_slide))
            else
                regs.pc +% @as(u64, @intCast(-self.aslr_slide));
        } else regs.pc;
        var cfa_ctx = CfaReaderCtx{
            .regs = regs,
            .process = &self.process,
            .allocator = self.allocator,
        };
        const result = unwind.unwindCfa(
            eh_frame_data,
            target_pc,
            @ptrCast(&cfa_ctx),
            &CfaReaderCtx.regReader,
            &CfaReaderCtx.memReader,
            if (self.eh_frame_index) |*idx| idx else null,
            if (self.cie_cache) |*cc| cc else null,
            self.allocator,
            self.is_debug_frame,
        ) orelse return null;
        return result.cfa;
    }

    fn buildLocals(self: *DwarfEngine, regs: process_mod.RegisterState) ![]const types.Variable {
        const dd = self.resolveDebugData() orelse return &.{};

        // Compute DWARF PC (un-slide)
        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        {
            const f = std.fs.cwd().createFile("/tmp/cog-dwarf-debug.log", .{ .truncate = false }) catch null;
            if (f) |file| {
                defer file.close();
                file.seekFromEnd(0) catch {};
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "buildLocals: regs.pc=0x{x}, aslr_slide={d}, dwarf_pc=0x{x}, has_loc={}, has_loclists={}\n", .{
                    regs.pc,
                    self.aslr_slide,
                    dwarf_pc,
                    dd.loc_data != null,
                    dd.loclists_data != null,
                }) catch "buildLocals: fmt error\n";
                file.writeAll(msg) catch {};
            }
        }

        var scoped = parser.parseScopedVariables(
            dd.info_data,
            dd.abbrev_data,
            dd.str_data,
            .{
                .debug_str_offsets = dd.str_offsets_data,
                .debug_addr = dd.addr_data,
                .debug_ranges = dd.ranges_data,
                .debug_rnglists = dd.rnglists_data,
                .debug_loc = dd.loc_data,
                .debug_loclists = dd.loclists_data,
            },
            dwarf_pc,
            self.allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch return &.{};
        defer parser.freeScopedVariables(scoped, self.allocator);

        // Nearest line entry fallback: handles DWARF location list gaps after stepping
        if (scoped.variables.len == 0 and self.line_entries.len > 0) {
            const best_addr = self.findNearestDwarfLineAddress(dwarf_pc);
            if (best_addr != 0 and best_addr != dwarf_pc) {
                const fallback_scoped = parser.parseScopedVariables(
                    dd.info_data,
                    dd.abbrev_data,
                    dd.str_data,
                    .{
                        .debug_str_offsets = dd.str_offsets_data,
                        .debug_addr = dd.addr_data,
                        .debug_ranges = dd.ranges_data,
                        .debug_rnglists = dd.rnglists_data,
                        .debug_loc = dd.loc_data,
                        .debug_loclists = dd.loclists_data,
                    },
                    best_addr,
                    self.allocator,
                    if (self.abbrev_cache) |*ac| ac else null,
                    self.cuHintForPC(best_addr),
                    if (self.type_die_cache) |*tdc| tdc else null,
                ) catch scoped;
                if (fallback_scoped.variables.len > 0) {
                    parser.freeScopedVariables(scoped, self.allocator);
                    scoped = fallback_scoped;
                } else if (fallback_scoped.variables.ptr != scoped.variables.ptr) {
                    parser.freeScopedVariables(fallback_scoped, self.allocator);
                }
            }
        }

        if (scoped.variables.len == 0) return &.{};

        // Build register and memory adapters
        var reg_adapter = RegisterAdapter{ .regs = regs };
        const reg_provider = reg_adapter.provider();
        var mem_adapter = MemoryAdapter{ .process = &self.process, .allocator = self.allocator };
        const mem_reader = mem_adapter.reader();

        // Evaluate frame base (pass real CFA from .eh_frame for DW_OP_call_frame_cfa)
        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(regs) });
            break :blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Evaluate each variable
        var locals = std.ArrayListUnmanaged(types.Variable).empty;
        errdefer locals.deinit(self.allocator);

        {
            const f2 = std.fs.cwd().createFile("/tmp/cog-dwarf-debug.log", .{ .truncate = false }) catch null;
            if (f2) |file2| {
                defer file2.close();
                file2.seekFromEnd(0) catch {};
                var buf2: [512]u8 = undefined;
                const msg2 = std.fmt.bufPrint(&buf2, "buildLocals: frame_base={?}, cfa={?}, sp=0x{x}, fp=0x{x}, num_vars={}\n", .{
                    frame_base,
                    self.computeCfa(regs),
                    regs.sp,
                    regs.fp,
                    scoped.variables.len,
                }) catch "buildLocals frame_base: fmt error\n";
                file2.writeAll(msg2) catch {};
            }
        }

        for (scoped.variables) |v| {
            if (v.location_expr.len == 0) continue;

            const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);

            {
                const f3 = std.fs.cwd().createFile("/tmp/cog-dwarf-debug.log", .{ .truncate = false }) catch null;
                if (f3) |file3| {
                    defer file3.close();
                    file3.seekFromEnd(0) catch {};
                    var buf3: [512]u8 = undefined;
                    var p3: usize = 0;
                    p3 += (std.fmt.bufPrint(buf3[p3..], "  var {s}: loc_type={s}", .{
                        v.name,
                        switch (loc) {
                            .address => "address",
                            .register => "register",
                            .value => "value",
                            .empty => "empty",
                            .implicit_pointer => "implicit_pointer",
                            .composite => "composite",
                        },
                    }) catch "").len;
                    p3 += (switch (loc) {
                        .address => |a| std.fmt.bufPrint(buf3[p3..], " addr=0x{x}", .{a}),
                        .register => |r| std.fmt.bufPrint(buf3[p3..], " reg={}", .{r}),
                        .value => |val| std.fmt.bufPrint(buf3[p3..], " val=0x{x}", .{val}),
                        else => std.fmt.bufPrint(buf3[p3..], "", .{}),
                    } catch "").len;
                    p3 += (std.fmt.bufPrint(buf3[p3..], " expr_bytes=", .{}) catch "").len;
                    for (v.location_expr) |b| {
                        p3 += (std.fmt.bufPrint(buf3[p3..], "{x:0>2}", .{b}) catch "").len;
                    }
                    if (p3 < buf3.len) { buf3[p3] = '\n'; p3 += 1; }
                    file3.writeAll(buf3[0..p3]) catch {};
                }
            }

            var fmt_buf: [64]u8 = undefined;
            const value_str = switch (loc) {
                .value => |val| blk: {
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, val, .little);
                    const effective_size: u8 = if (v.type_byte_size > 0 and v.type_byte_size <= 8) @intCast(v.type_byte_size) else 8;
                    break :blk location.formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                },
                .address => |addr| blk: {
                    const raw_size: usize = if (v.type_byte_size > 0) v.type_byte_size else 4;
                    // Cap read size to 8 bytes (u64 buffer limit)
                    const size: usize = @min(raw_size, 8);
                    const mval = mem_reader.read(addr, size) orelse break :blk "<unreadable>";
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, mval, .little);
                    break :blk location.formatVariable(raw[0..size], v.type_name, v.type_encoding, @intCast(size), &fmt_buf);
                },
                .register => |reg| blk: {
                    const rval = reg_provider.read(reg) orelse break :blk "<unavailable>";
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, rval, .little);
                    const effective_size: u8 = if (v.type_byte_size > 0 and v.type_byte_size <= 8) @intCast(v.type_byte_size) else 8;
                    break :blk location.formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                },
                .implicit_pointer => "<implicit pointer>",
                .composite => "<composite>",
                .empty => continue,
            };

            const value_owned = try self.allocator.dupe(u8, value_str);
            try locals.append(self.allocator, .{
                .name = v.name,
                .value = value_owned,
                .@"type" = v.type_name,
            });
        }

        return try locals.toOwnedSlice(self.allocator);
    }

    fn cacheStackTrace(self: *DwarfEngine, stack_trace: []const types.StackFrame) void {
        // Free previous cached trace
        if (self.cached_stack_trace.len > 0) {
            self.allocator.free(self.cached_stack_trace);
        }
        // Duplicate the new trace for caching
        if (stack_trace.len > 0) {
            self.cached_stack_trace = self.allocator.dupe(types.StackFrame, stack_trace) catch &.{};
        } else {
            self.cached_stack_trace = &.{};
        }
    }

    fn stepPastBreakpoint(self: *DwarfEngine, bp_addr: u64) !void {
        if (self.bp_manager.findByAddress(bp_addr)) |bp| {
            // 1. Restore original bytes
            try self.process.writeMemory(bp_addr, &bp.original_bytes);

            // 2. Single-step past the original instruction
            try self.process.singleStep();
            _ = try self.process.waitForStop();

            // 3. Re-insert trap instruction
            try self.process.writeMemory(bp_addr, breakpoint_mod.trap_instruction);
        }
    }

    /// Step past a hardware watchpoint: temporarily disable it, single-step the
    /// faulting instruction, then re-enable. On ARM64, watchpoints fire BEFORE the
    /// instruction executes, so without this the watchpoint re-fires immediately.
    fn stepPastWatchpoint(self: *DwarfEngine, slot: u32) !void {
        // 1. Temporarily disable the watchpoint in hardware
        try self.process.clearHardwareWatchpoint(slot);

        // 2. Single-step past the faulting instruction
        try self.process.singleStep();
        _ = try self.process.waitForStop();

        // 3. Re-enable the watchpoint if still tracked as active
        if (self.hw_watchpoints[slot].active) {
            const wp = self.hw_watchpoints[slot];
            _ = try self.process.setHardwareWatchpoint(wp.address, @intCast(wp.size), @intCast(wp.access_type));
        }
    }

    fn rearmAllBreakpoints(self: *DwarfEngine) void {
        for (self.bp_manager.breakpoints.items) |*bp| {
            if (bp.enabled) {
                self.bp_manager.writeBreakpoint(bp.id, &self.process) catch {};
            }
        }
    }

    // ── Breakpoints ─────────────────────────────────────────────────

    fn engineSetBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8, log_message: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.core_dump != null) return error.NotSupported; // core dumps are read-only

        if (self.line_entries.len > 0) {
            // Resolve file:line to address via DWARF line table
            const bp = try self.bp_manager.resolveAndSetEx(file, line, self.line_entries, self.file_entries, condition, hit_condition, log_message);

            // Write INT3 into the process
            self.bp_manager.writeBreakpoint(bp.id, &self.process) catch |err| {
                // If write fails, remove the breakpoint and propagate
                self.bp_manager.remove(bp.id) catch {};
                return err;
            };

            return .{
                .id = bp.id,
                .verified = true,
                .file = bp.file,
                .line = bp.line,
                .condition = condition,
                .hit_condition = hit_condition,
            };
        }

        // No debug info — return unverified breakpoint
        return .{ .id = 0, .verified = false, .file = file, .line = line };
    }

    fn engineRemoveBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, id: u32) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        // Hardware watchpoint IDs are slot + 1000
        if (id >= 1000 and id < 1004) {
            const slot: u32 = id - 1000;
            if (self.hw_watchpoints[slot].active) {
                try self.process.clearHardwareWatchpoint(slot);
                self.hw_watchpoints[slot] = .{};
                // Clear step-past state if we were about to step past this one
                if (self.stepping_past_wp) |wp_slot| {
                    if (wp_slot == slot) self.stepping_past_wp = null;
                }
            }
            return;
        }

        // Existing software breakpoint removal
        self.bp_manager.removeBreakpoint(id, &self.process) catch {
            // If process write fails, at least remove from list
            self.bp_manager.remove(id) catch {};
        };
    }

    fn engineListBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const bps = self.bp_manager.list();

        // Count active hardware watchpoints
        var wp_count: usize = 0;
        for (self.hw_watchpoints) |wp| {
            if (wp.active) wp_count += 1;
        }

        if (bps.len == 0 and wp_count == 0) return &.{};

        const result = try allocator.alloc(BreakpointInfo, bps.len + wp_count);
        for (bps, 0..) |bp, i| {
            result[i] = .{
                .id = bp.id,
                .verified = bp.enabled,
                .file = bp.file,
                .line = bp.line,
                .condition = bp.condition,
                .hit_condition = bp.hit_condition,
            };
        }

        // Append active hardware watchpoints
        var wp_idx: usize = 0;
        for (self.hw_watchpoints) |wp| {
            if (!wp.active) continue;
            result[bps.len + wp_idx] = .{
                .id = wp.id,
                .verified = true,
                .file = "",
                .line = 0,
            };
            wp_idx += 1;
        }
        return result;
    }

    // ── Inspect ─────────────────────────────────────────────────────

    fn engineInspect(ctx: *anyopaque, allocator: std.mem.Allocator, request: InspectRequest) anyerror!InspectResult {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        // Map variablesReference IDs from engineScopes to scope filters
        // 1 = Locals, 2 = Arguments (assigned in engineScopes)
        var effective_scope: ?[]const u8 = request.scope;
        var is_variable_ref_request = false;
        if (request.variable_ref) |ref| {
            if (ref == 1) {
                effective_scope = "locals";
                is_variable_ref_request = true;
            } else if (ref == 2) {
                effective_scope = "arguments";
                is_variable_ref_request = true;
            } else if (ref > 0) {
                return .{
                    .result = try allocator.dupe(u8, "<invalid variable reference>"),
                    .@"type" = "",
                    .result_allocated = true,
                };
            }
        }

        // 1. Read registers to get current PC
        const regs = self.process.readRegisters() catch {
            return .{ .result = "<no process>", .@"type" = "" };
        };

        // 2. Find a debug binary with debug_info section (prefer dSYM, then main binary)
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return .{ .result = "<no debug info>", .@"type" = "" };
        };

        // 3. Extract section data
        const info_section = debug_binary.sections.debug_info orelse return .{ .result = "<no debug info>", .@"type" = "" };
        const abbrev_section = debug_binary.sections.debug_abbrev orelse return .{ .result = "<no debug info>", .@"type" = "" };
        const info_data = debug_binary.getSectionData(info_section) orelse return .{ .result = "<no debug info>", .@"type" = "" };
        const abbrev_data = debug_binary.getSectionData(abbrev_section) orelse return .{ .result = "<no debug info>", .@"type" = "" };
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null;

        // 4. Determine the PC to use for variable lookup
        // If frame_id is provided, look up that frame's PC from the cached stack trace
        const target_pc: u64 = if (request.frame_id) |frame_id| blk: {
            for (self.cached_stack_trace) |frame| {
                if (frame.id == frame_id) {
                    // Use the frame's stored address directly (un-slide for DWARF comparison)
                    if (frame.address != 0) {
                        break :blk if (self.aslr_slide >= 0)
                            frame.address -% @as(u64, @intCast(self.aslr_slide))
                        else
                            frame.address +% @as(u64, @intCast(-self.aslr_slide));
                    }
                    break;
                }
            }
            // Fall back to current PC if frame not found
            break :blk if (self.aslr_slide >= 0)
                regs.pc -% @as(u64, @intCast(self.aslr_slide))
            else
                regs.pc +% @as(u64, @intCast(-self.aslr_slide));
        } else blk: {
            // No frame_id: use current PC (un-slide for DWARF comparison)
            break :blk if (self.aslr_slide >= 0)
                regs.pc -% @as(u64, @intCast(self.aslr_slide))
            else
                regs.pc +% @as(u64, @intCast(-self.aslr_slide));
        };

        // 5. Parse scoped variables for the target function
        var scoped = parser.parseScopedVariables(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
            },
            target_pc,
            allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(target_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch {
            return .{ .result = "<parse error>", .@"type" = "" };
        };
        defer parser.freeScopedVariables(scoped, allocator);

        // 5b. Split DWARF fallback: if skeleton CU has no variables, try DWO binaries
        if (scoped.variables.len == 0) {
            // Try Mach-O DWO binaries
            for (self.dwo_binaries) |dwo| {
                const dwo_scoped = self.parseDwoVariables(&dwo, addr_data, target_pc, allocator) catch continue;
                if (dwo_scoped.variables.len > 0) {
                    parser.freeScopedVariables(scoped, allocator);
                    scoped = dwo_scoped;
                    break;
                } else {
                    parser.freeScopedVariables(dwo_scoped, allocator);
                }
            }
            // If still empty, try ELF DWO binaries
            if (scoped.variables.len == 0) {
                for (self.dwo_elf_binaries) |dwo_elf| {
                    const dwo_scoped = self.parseDwoElfVariables(&dwo_elf, addr_data, target_pc, allocator) catch continue;
                    if (dwo_scoped.variables.len > 0) {
                        parser.freeScopedVariables(scoped, allocator);
                        scoped = dwo_scoped;
                        break;
                    } else {
                        parser.freeScopedVariables(dwo_scoped, allocator);
                    }
                }
            }
        }

        // 5c. Nearest line entry fallback: handles DWARF location list gaps after stepping
        if (scoped.variables.len == 0 and self.line_entries.len > 0) {
            const best_addr = self.findNearestDwarfLineAddress(target_pc);
            if (best_addr != 0 and best_addr != target_pc) {
                const fallback_scoped = parser.parseScopedVariables(
                    info_data,
                    abbrev_data,
                    str_data,
                    .{
                        .debug_str_offsets = str_offsets_data,
                        .debug_addr = addr_data,
                        .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                        .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                        .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                        .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
                    },
                    best_addr,
                    allocator,
                    if (self.abbrev_cache) |*ac| ac else null,
                    self.cuHintForPC(best_addr),
                    if (self.type_die_cache) |*tdc| tdc else null,
                ) catch scoped;
                if (fallback_scoped.variables.len > 0) {
                    parser.freeScopedVariables(scoped, allocator);
                    scoped = fallback_scoped;
                } else if (fallback_scoped.variables.ptr != scoped.variables.ptr) {
                    parser.freeScopedVariables(fallback_scoped, allocator);
                }
            }
        }

        // 6. Filter variables by scope if requested (using effective_scope which may come from variable_ref)
        const scope_filter: ?parser.VariableScope = if (effective_scope) |scope_str| blk: {
            if (std.mem.eql(u8, scope_str, "locals")) break :blk .local;
            if (std.mem.eql(u8, scope_str, "arguments")) break :blk .argument;
            break :blk null; // "all" or unrecognized — no filter
        } else null;

        var filtered_vars: []const parser.VariableInfo = scoped.variables;
        var filtered_buf: std.ArrayListUnmanaged(parser.VariableInfo) = .empty;
        defer filtered_buf.deinit(allocator);

        if (scope_filter) |filter| {
            for (scoped.variables) |v| {
                if (v.scope == filter) {
                    filtered_buf.append(allocator, v) catch continue;
                }
            }
            filtered_vars = filtered_buf.items;
        }

        // 7. Adjust registers for target frame — use frame's FP, PC, SP for parent frame inspection.
        //    Also sync GPR array entries so RegisterAdapter reads the same values as CfaReaderCtx.
        var frame_regs = regs;
        if (request.frame_id) |frame_id| {
            if (frame_id > 0) {
                for (self.cached_stack_trace) |frame| {
                    if (frame.id == frame_id) {
                        if (frame.fp != 0) {
                            frame_regs.fp = frame.fp;
                            // Sync GPR array so RegisterAdapter reads correct FP
                            if (builtin.cpu.arch == .aarch64) {
                                frame_regs.gprs[29] = frame.fp; // x29 = FP
                            } else if (builtin.cpu.arch == .x86_64) {
                                frame_regs.gprs[6] = frame.fp; // RBP
                            }
                        }
                        if (frame.address != 0) frame_regs.pc = frame.address;
                        if (frame.sp != 0) {
                            frame_regs.sp = frame.sp;
                            if (builtin.cpu.arch == .aarch64) {
                                frame_regs.gprs[31] = frame.sp; // x31 = SP
                            } else if (builtin.cpu.arch == .x86_64) {
                                frame_regs.gprs[7] = frame.sp; // RSP
                            }
                        }
                        break;
                    }
                }
            }
        }

        // 8. If no expression (or variable_ref request), return all variables in the requested scope
        if (is_variable_ref_request) {
            return self.buildScopeResult(filtered_vars, frame_regs, scoped.frame_base_expr, allocator);
        }
        const expr_str = request.expression orelse {
            return self.buildScopeResult(filtered_vars, frame_regs, scoped.frame_base_expr, allocator);
        };
        if (expr_str.len == 0) {
            return self.buildScopeResult(filtered_vars, frame_regs, scoped.frame_base_expr, allocator);
        }

        if (filtered_vars.len == 0) {
            return .{ .result = "<no variables in scope>", .@"type" = "" };
        }

        // 9. Build register adapter
        var reg_adapter = RegisterAdapter{ .regs = frame_regs };
        const reg_provider = reg_adapter.provider();

        // 10. Build memory adapter
        var mem_adapter = MemoryAdapter{ .process = &self.process, .allocator = allocator };
        const mem_reader = mem_adapter.reader();

        // 11. Evaluate frame base expression (pass real CFA for DW_OP_call_frame_cfa)
        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(frame_regs) });
            break :blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // 12. Evaluate the expression
        return evaluateExpression(
            expr_str,
            filtered_vars,
            reg_provider,
            frame_base,
            mem_reader,
            allocator,
        );
    }

    /// When no expression is given but scope is specified, return all variables in that scope
    fn buildScopeResult(self: *DwarfEngine, variables: []const parser.VariableInfo, regs: process_mod.RegisterState, frame_base_expr: []const u8, allocator: std.mem.Allocator) InspectResult {
        if (variables.len == 0) {
            return .{ .result = "<no variables in scope>", .@"type" = "" };
        }

        // Build adapters
        var reg_adapter = RegisterAdapter{ .regs = regs };
        const reg_provider = reg_adapter.provider();
        var mem_adapter = MemoryAdapter{ .process = &self.process, .allocator = allocator };
        const mem_reader = mem_adapter.reader();

        // Evaluate frame base (pass real CFA for DW_OP_call_frame_cfa)
        const frame_base: ?u64 = if (frame_base_expr.len > 0) blk: {
            const fb_result = location.evalLocationEx(frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(regs) });
            break :blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Build children list with all variables
        var children = std.ArrayListUnmanaged(types.Variable).empty;
        for (variables) |v| {
            if (v.location_expr.len == 0) continue;

            const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);
            var fmt_buf: [64]u8 = undefined;
            const value_str = switch (loc) {
                .value => |val| blk: {
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, val, .little);
                    const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                    break :blk location.formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                },
                .address => |addr| blk: {
                    const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 4;
                    const mval = mem_reader.read(addr, size) orelse break :blk "<unreadable>";
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, mval, .little);
                    break :blk location.formatVariable(raw[0..size], v.type_name, v.type_encoding, @intCast(size), &fmt_buf);
                },
                .register => |reg| blk: {
                    const rval = reg_provider.read(reg) orelse break :blk "<unavailable>";
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, rval, .little);
                    const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                    break :blk location.formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                },
                .implicit_pointer => "<implicit pointer>",
                .composite => "<composite>",
                .empty => continue,
            };

            const value_owned = allocator.dupe(u8, value_str) catch continue;
            children.append(allocator, .{
                .name = v.name,
                .value = value_owned,
                .@"type" = v.type_name,
            }) catch continue;
        }

        const scope_label = if (children.items.len > 0) "scope variables" else "<no variables in scope>";
        return .{
            .result = scope_label,
            .@"type" = "scope",
            .children = children.toOwnedSlice(allocator) catch &.{},
        };
    }

    // ── Split DWARF Helpers ────────────────────────────────────────

    /// Parse scoped variables from a Mach-O DWO binary, using the main binary's .debug_addr.
    fn parseDwoVariables(
        _: *const DwarfEngine,
        dwo: *const binary_macho.MachoBinary,
        main_addr_data: ?[]const u8,
        target_pc: u64,
        allocator: std.mem.Allocator,
    ) !parser.ScopedVariableResult {
        const dwo_info = if (dwo.sections.debug_info) |s| dwo.getSectionData(s) orelse return error.NoData else return error.NoData;
        const dwo_abbrev = if (dwo.sections.debug_abbrev) |s| dwo.getSectionData(s) orelse return error.NoData else return error.NoData;
        const dwo_str = if (dwo.sections.debug_str) |s| dwo.getSectionData(s) else null;
        return parser.parseScopedVariables(
            dwo_info,
            dwo_abbrev,
            dwo_str,
            .{
                .debug_str_offsets = if (dwo.sections.debug_str_offsets) |s| dwo.getSectionData(s) else null,
                .debug_addr = main_addr_data,
                .debug_ranges = if (dwo.sections.debug_ranges) |s| dwo.getSectionData(s) else null,
                .debug_rnglists = if (dwo.sections.debug_rnglists) |s| dwo.getSectionData(s) else null,
                .debug_loc = if (dwo.sections.debug_loc) |s| dwo.getSectionData(s) else null,
                .debug_loclists = if (dwo.sections.debug_loclists) |s| dwo.getSectionData(s) else null,
            },
            target_pc,
            allocator,
            null,
            null,
            null,
        );
    }

    /// Parse scoped variables from an ELF DWO binary, using the main binary's .debug_addr.
    fn parseDwoElfVariables(
        _: *const DwarfEngine,
        dwo: *const binary_elf.ElfBinary,
        main_addr_data: ?[]const u8,
        target_pc: u64,
        allocator: std.mem.Allocator,
    ) !parser.ScopedVariableResult {
        const dwo_info = if (dwo.sections.debug_info) |s| dwo.getSectionData(s) orelse return error.NoData else return error.NoData;
        const dwo_abbrev = if (dwo.sections.debug_abbrev) |s| dwo.getSectionData(s) orelse return error.NoData else return error.NoData;
        const dwo_str = if (dwo.sections.debug_str) |s| dwo.getSectionData(s) else null;
        return parser.parseScopedVariables(
            dwo_info,
            dwo_abbrev,
            dwo_str,
            .{
                .debug_str_offsets = if (dwo.sections.debug_str_offsets) |s| dwo.getSectionData(s) else null,
                .debug_addr = main_addr_data,
                .debug_ranges = if (dwo.sections.debug_ranges) |s| dwo.getSectionData(s) else null,
                .debug_rnglists = if (dwo.sections.debug_rnglists) |s| dwo.getSectionData(s) else null,
                .debug_loc = if (dwo.sections.debug_loc) |s| dwo.getSectionData(s) else null,
                .debug_loclists = if (dwo.sections.debug_loclists) |s| dwo.getSectionData(s) else null,
            },
            target_pc,
            allocator,
            null,
            null,
            null,
        );
    }

    // ── Inspect Helpers ─────────────────────────────────────────────

    const RegisterAdapter = struct {
        regs: process_mod.RegisterState,

        fn readReg(ctx: *anyopaque, reg: u64) ?u64 {
            const self: *RegisterAdapter = @ptrCast(@alignCast(ctx));
            if (reg < 32) {
                return self.regs.gprs[@intCast(reg)];
            }
            // Architecture-specific special registers
            if (builtin.cpu.arch == .aarch64) {
                return switch (reg) {
                    32 => self.regs.pc, // PC
                    else => null,
                };
            }
            // x86_64 - DWARF reg 16 is RIP (already in gprs[16])
            return null;
        }

        fn provider(self: *RegisterAdapter) location.RegisterProvider {
            return .{
                .ptr = @ptrCast(self),
                .readFn = readReg,
            };
        }
    };

    const MemoryAdapter = struct {
        process: *ProcessControl,
        allocator: std.mem.Allocator,

        fn readMem(ctx: *anyopaque, addr: u64, size: usize) ?u64 {
            const self: *MemoryAdapter = @ptrCast(@alignCast(ctx));
            const buf = self.process.readMemory(addr, size, self.allocator) catch return null;
            defer self.allocator.free(buf);
            if (buf.len == 0) return null;
            return switch (buf.len) {
                1 => buf[0],
                2 => std.mem.readInt(u16, buf[0..2], .little),
                4 => std.mem.readInt(u32, buf[0..4], .little),
                8 => std.mem.readInt(u64, buf[0..8], .little),
                else => blk: {
                    // For other sizes, read up to 8 bytes
                    var result: u64 = 0;
                    for (buf, 0..) |byte, i| {
                        if (i >= 8) break;
                        result |= @as(u64, byte) << @intCast(@as(u6, @intCast(i * 8)));
                    }
                    break :blk result;
                },
            };
        }

        fn reader(self: *MemoryAdapter) location.MemoryReader {
            return .{
                .ptr = @ptrCast(self),
                .readFn = readMem,
            };
        }
    };

    fn evaluateExpression(
        expr_str: []const u8,
        variables: []const parser.VariableInfo,
        reg_provider: location.RegisterProvider,
        frame_base: ?u64,
        mem_reader: location.MemoryReader,
        allocator: std.mem.Allocator,
    ) InspectResult {
        // Try to find a binary operator in the expression
        if (findBinaryOperator(expr_str)) |op_info| {
            const lhs_token = std.mem.trim(u8, expr_str[0..op_info.pos], " ");
            const rhs_token = std.mem.trim(u8, expr_str[op_info.pos + op_info.len ..], " ");

            const lhs_val = resolveOperand(lhs_token, variables, reg_provider, frame_base, mem_reader) orelse {
                return .{ .result = "<unknown variable>", .@"type" = "" };
            };
            const rhs_val = resolveOperand(rhs_token, variables, reg_provider, frame_base, mem_reader) orelse {
                return .{ .result = "<unknown variable>", .@"type" = "" };
            };

            const result_val: i64 = switch (op_info.op) {
                .add => lhs_val + rhs_val,
                .sub => lhs_val - rhs_val,
                .mul => lhs_val * rhs_val,
                .div => if (rhs_val != 0) @divTrunc(lhs_val, rhs_val) else 0,
            };

            var buf: [64]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}", .{result_val}) catch return .{ .result = "<format error>", .@"type" = "" };
            const result_str = allocator.dupe(u8, formatted) catch return .{ .result = "<alloc error>", .@"type" = "" };
            const type_owned = allocator.dupe(u8, "int") catch return .{ .result = result_str, .@"type" = "", .result_allocated = true };
            return .{ .result = result_str, .@"type" = type_owned, .result_allocated = true };
        }

        // Single variable lookup
        const trimmed = std.mem.trim(u8, expr_str, " ");
        return evaluateSingleVariable(trimmed, variables, reg_provider, frame_base, mem_reader, allocator);
    }

    const BinaryOp = enum { add, sub, mul, div };

    const OpInfo = struct {
        pos: usize,
        len: usize,
        op: BinaryOp,
    };

    fn findBinaryOperator(expr: []const u8) ?OpInfo {
        // Scan for +, -, *, / with spaces around them (to avoid matching negative numbers)
        // Search from left to right for lowest-precedence operators first
        var i: usize = 1; // Start at 1 to skip potential unary operator
        while (i < expr.len) : (i += 1) {
            const c = expr[i];
            if ((c == '+' or c == '-') and i > 0 and i + 1 < expr.len) {
                // Check there's at least some content on both sides
                const left = std.mem.trim(u8, expr[0..i], " ");
                const right = std.mem.trim(u8, expr[i + 1 ..], " ");
                if (left.len > 0 and right.len > 0) {
                    return .{
                        .pos = i,
                        .len = 1,
                        .op = if (c == '+') .add else .sub,
                    };
                }
            }
        }
        // Second pass for * and /
        i = 1;
        while (i < expr.len) : (i += 1) {
            const c = expr[i];
            if ((c == '*' or c == '/') and i > 0 and i + 1 < expr.len) {
                const left = std.mem.trim(u8, expr[0..i], " ");
                const right = std.mem.trim(u8, expr[i + 1 ..], " ");
                if (left.len > 0 and right.len > 0) {
                    return .{
                        .pos = i,
                        .len = 1,
                        .op = if (c == '*') .mul else .div,
                    };
                }
            }
        }
        return null;
    }

    /// Evaluate a condition expression (e.g. "i > 3", "x == 0", "flag != 1") and return
    /// true if the condition is met. Supports: ==, !=, >=, <=, >, <
    fn evaluateCondition(
        condition: []const u8,
        variables: []const parser.VariableInfo,
        reg_provider: location.RegisterProvider,
        frame_base: ?u64,
        mem_reader: location.MemoryReader,
    ) bool {
        // Try to find a comparison operator
        const comparisons = [_]struct { op: []const u8, len: u8 }{
            .{ .op = "!=", .len = 2 },
            .{ .op = ">=", .len = 2 },
            .{ .op = "<=", .len = 2 },
            .{ .op = "==", .len = 2 },
            .{ .op = ">", .len = 1 },
            .{ .op = "<", .len = 1 },
        };

        for (comparisons) |cmp| {
            if (std.mem.indexOf(u8, condition, cmp.op)) |pos| {
                // Don't match '>' inside '>=' — skip if next char makes a longer operator
                if (cmp.len == 1 and pos + 1 < condition.len) {
                    if (condition[pos + 1] == '=') continue;
                }
                // Don't match '<' inside '<=' or '!' inside '!='
                if (cmp.len == 1 and pos > 0) {
                    if (cmp.op[0] == '=' and (condition[pos - 1] == '!' or condition[pos - 1] == '>' or condition[pos - 1] == '<')) continue;
                }

                const lhs_token = std.mem.trim(u8, condition[0..pos], " ");
                const rhs_token = std.mem.trim(u8, condition[pos + cmp.len ..], " ");
                if (lhs_token.len == 0 or rhs_token.len == 0) continue;

                const lhs = resolveOperand(lhs_token, variables, reg_provider, frame_base, mem_reader) orelse return true;
                const rhs = resolveOperand(rhs_token, variables, reg_provider, frame_base, mem_reader) orelse return true;

                if (std.mem.eql(u8, cmp.op, "==")) return lhs == rhs;
                if (std.mem.eql(u8, cmp.op, "!=")) return lhs != rhs;
                if (std.mem.eql(u8, cmp.op, ">=")) return lhs >= rhs;
                if (std.mem.eql(u8, cmp.op, "<=")) return lhs <= rhs;
                if (std.mem.eql(u8, cmp.op, ">")) return lhs > rhs;
                if (std.mem.eql(u8, cmp.op, "<")) return lhs < rhs;
            }
        }

        // No comparison operator found — try to evaluate as an expression.
        // Non-zero = true, zero = false.
        const val = resolveOperand(std.mem.trim(u8, condition, " "), variables, reg_provider, frame_base, mem_reader) orelse return true;
        return val != 0;
    }

    /// Context for condition evaluation, capturing DWARF state needed by evaluateCondition.
    const ConditionContext = struct {
        variables: []const parser.VariableInfo,
        reg_adapter: RegisterAdapter,
        mem_adapter: MemoryAdapter,
        frame_base: ?u64,
        scoped_result: ?parser.ScopedVariableResult,
        allocator: std.mem.Allocator,

        fn evalFn(ctx: *anyopaque, condition: []const u8) bool {
            const self: *ConditionContext = @ptrCast(@alignCast(ctx));
            const reg_provider = self.reg_adapter.provider();
            const mem_reader = self.mem_adapter.reader();
            return evaluateCondition(condition, self.variables, reg_provider, self.frame_base, mem_reader);
        }

        fn deinit(self: *ConditionContext) void {
            if (self.scoped_result) |scoped| {
                parser.freeScopedVariables(scoped, self.allocator);
            }
        }
    };

    /// Build a ConditionEvaluator that can evaluate breakpoint conditions against the
    /// current DWARF state (registers, memory, scoped variables at current PC).
    /// The caller must call condition_context.deinit() when done.
    fn buildConditionEvaluator(self: *DwarfEngine, regs: process_mod.RegisterState) ?BreakpointManager.ConditionEvaluator {
        // Find debug binary with debug_info section
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return null;
        };

        const info_section = debug_binary.sections.debug_info orelse return null;
        const abbrev_section = debug_binary.sections.debug_abbrev orelse return null;
        const info_data = debug_binary.getSectionData(info_section) orelse return null;
        const abbrev_data = debug_binary.getSectionData(abbrev_section) orelse return null;
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null;

        // Compute DWARF PC (un-slide)
        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        const scoped = parser.parseScopedVariables(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
            },
            dwarf_pc,
            self.allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch return null;

        if (scoped.variables.len == 0) {
            parser.freeScopedVariables(scoped, self.allocator);
            return null;
        }

        // Build register and memory adapters
        var reg_adapter = RegisterAdapter{ .regs = regs };
        const reg_provider = reg_adapter.provider();

        // Evaluate frame base (pass real CFA for DW_OP_call_frame_cfa)
        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) fb_blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(regs) });
            break :fb_blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Store context in engine's condition_context field
        self.condition_context = .{
            .variables = scoped.variables,
            .reg_adapter = .{ .regs = regs },
            .mem_adapter = .{ .process = &self.process, .allocator = self.allocator },
            .frame_base = frame_base,
            .scoped_result = scoped,
            .allocator = self.allocator,
        };

        return .{
            .ctx = @ptrCast(&self.condition_context.?),
            .evalFn = ConditionContext.evalFn,
        };
    }

    /// Evaluate a log point message template, replacing {varname} with variable values.
    fn evaluateLogMessage(self: *DwarfEngine, template: []const u8, regs: process_mod.RegisterState) ?[]const u8 {
        // Get DWARF sections for variable resolution
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return self.allocator.dupe(u8, template) catch null;
        };

        const info_section = debug_binary.sections.debug_info orelse return self.allocator.dupe(u8, template) catch null;
        const abbrev_section = debug_binary.sections.debug_abbrev orelse return self.allocator.dupe(u8, template) catch null;
        const info_data = debug_binary.getSectionData(info_section) orelse return self.allocator.dupe(u8, template) catch null;
        const abbrev_data = debug_binary.getSectionData(abbrev_section) orelse return self.allocator.dupe(u8, template) catch null;
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null;

        // Compute DWARF PC
        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        const scoped = parser.parseScopedVariables(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
            },
            dwarf_pc,
            self.allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch return self.allocator.dupe(u8, template) catch null;
        defer parser.freeScopedVariables(scoped, self.allocator);

        var reg_adapter = RegisterAdapter{ .regs = regs };
        const reg_provider = reg_adapter.provider();
        var mem_adapter = MemoryAdapter{ .process = &self.process, .allocator = self.allocator };
        const mem_reader = mem_adapter.reader();

        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) fb_blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(regs) });
            break :fb_blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Build result by replacing {varname} with values
        var result = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '{') {
                if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |close| {
                    const var_name = template[i + 1 .. close];
                    if (var_name.len > 0) {
                        if (readVariableAsI64(var_name, scoped.variables, reg_provider, frame_base, mem_reader)) |val| {
                            var buf: [32]u8 = undefined;
                            const formatted = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "{?}";
                            result.appendSlice(self.allocator, formatted) catch {};
                        } else {
                            result.appendSlice(self.allocator, "{?}") catch {};
                        }
                        i = close + 1;
                        continue;
                    }
                }
            }
            result.append(self.allocator, template[i]) catch {};
            i += 1;
        }

        return result.toOwnedSlice(self.allocator) catch null;
    }

    fn resolveOperand(
        token: []const u8,
        variables: []const parser.VariableInfo,
        reg_provider: location.RegisterProvider,
        frame_base: ?u64,
        mem_reader: location.MemoryReader,
    ) ?i64 {
        // Try integer literal first
        if (std.fmt.parseInt(i64, token, 10)) |val| {
            return val;
        } else |_| {}

        // Try variable lookup
        return readVariableAsI64(token, variables, reg_provider, frame_base, mem_reader);
    }

    fn readVariableAsI64(
        name: []const u8,
        variables: []const parser.VariableInfo,
        reg_provider: location.RegisterProvider,
        frame_base: ?u64,
        mem_reader: location.MemoryReader,
    ) ?i64 {
        // Find the variable by name
        for (variables) |v| {
            if (std.mem.eql(u8, v.name, name)) {
                if (v.location_expr.len == 0) return null;

                const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);
                switch (loc) {
                    .value => |val| {
                        // Stack value — interpret based on type
                        return interpretAsI64(val, v.type_encoding, v.type_byte_size);
                    },
                    .address => |addr| {
                        // Read from process memory
                        const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 4;
                        const val = mem_reader.read(addr, size) orelse return null;
                        return interpretAsI64(val, v.type_encoding, v.type_byte_size);
                    },
                    .register => |reg| {
                        const val = reg_provider.read(reg) orelse return null;
                        return interpretAsI64(val, v.type_encoding, v.type_byte_size);
                    },
                    .empty, .implicit_pointer, .composite => return null,
                }
            }
        }
        return null;
    }

    fn interpretAsI64(raw: u64, encoding: u8, byte_size: u8) i64 {
        const DW_ATE_signed: u8 = 0x05;
        const DW_ATE_signed_char: u8 = 0x06;
        if (encoding == DW_ATE_signed or encoding == DW_ATE_signed_char) {
            return switch (byte_size) {
                1 => @as(i64, @as(i8, @bitCast(@as(u8, @truncate(raw))))),
                2 => @as(i64, @as(i16, @bitCast(@as(u16, @truncate(raw))))),
                4 => @as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw))))),
                8 => @bitCast(raw),
                else => @bitCast(raw),
            };
        }
        // Unsigned or unknown — treat as unsigned but return as i64
        return switch (byte_size) {
            1 => @as(i64, @intCast(raw & 0xFF)),
            2 => @as(i64, @intCast(raw & 0xFFFF)),
            4 => @as(i64, @intCast(raw & 0xFFFFFFFF)),
            else => @bitCast(raw),
        };
    }

    fn evaluateSingleVariable(
        name: []const u8,
        variables: []const parser.VariableInfo,
        reg_provider: location.RegisterProvider,
        frame_base: ?u64,
        mem_reader: location.MemoryReader,
        allocator: std.mem.Allocator,
    ) InspectResult {
        for (variables) |v| {
            if (std.mem.eql(u8, v.name, name)) {
                if (v.location_expr.len == 0) {
                    return .{ .result = "<optimized out>", .@"type" = v.type_name };
                }

                const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);

                var fmt_buf: [64]u8 = undefined;
                switch (loc) {
                    .value => |val| {
                        var raw: [8]u8 = undefined;
                        std.mem.writeInt(u64, &raw, val, .little);
                        const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                        const formatted = location.formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                        const result_str = allocator.dupe(u8, formatted) catch return .{ .result = "<alloc error>", .@"type" = "" };
                        const type_owned = allocator.dupe(u8, v.type_name) catch return .{ .result = result_str, .@"type" = "", .result_allocated = true };
                        return .{ .result = result_str, .@"type" = type_owned, .result_allocated = true };
                    },
                    .address => |addr| {
                        const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 4;
                        const val = mem_reader.read(addr, size) orelse {
                            return .{ .result = "<unreadable>", .@"type" = v.type_name };
                        };
                        var raw: [8]u8 = undefined;
                        std.mem.writeInt(u64, &raw, val, .little);
                        const formatted = location.formatVariable(raw[0..size], v.type_name, v.type_encoding, @intCast(size), &fmt_buf);
                        const result_str = allocator.dupe(u8, formatted) catch return .{ .result = "<alloc error>", .@"type" = "" };
                        const type_owned = allocator.dupe(u8, v.type_name) catch return .{ .result = result_str, .@"type" = "", .result_allocated = true };
                        return .{ .result = result_str, .@"type" = type_owned, .result_allocated = true };
                    },
                    .register => |reg| {
                        const val = reg_provider.read(reg) orelse {
                            return .{ .result = "<unavailable>", .@"type" = v.type_name };
                        };
                        var raw: [8]u8 = undefined;
                        std.mem.writeInt(u64, &raw, val, .little);
                        const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                        const formatted = location.formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                        const result_str = allocator.dupe(u8, formatted) catch return .{ .result = "<alloc error>", .@"type" = "" };
                        const type_owned = allocator.dupe(u8, v.type_name) catch return .{ .result = result_str, .@"type" = "", .result_allocated = true };
                        return .{ .result = result_str, .@"type" = type_owned, .result_allocated = true };
                    },
                    .implicit_pointer => {
                        return .{ .result = "<implicit pointer>", .@"type" = v.type_name };
                    },
                    .composite => {
                        return .{ .result = "<composite>", .@"type" = v.type_name };
                    },
                    .empty => {
                        return .{ .result = "<optimized out>", .@"type" = v.type_name };
                    },
                }
            }
        }
        return .{ .result = "<unknown variable>", .@"type" = "" };
    }

    // ── Threads ──────────────────────────────────────────────────────

    fn engineThreads(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const types.ThreadInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.process.pid == null) return error.NoProcess;

        if (builtin.os.tag != .macos) {
            // Single thread on non-macOS for now
            const result = try allocator.alloc(types.ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main", .is_stopped = !self.process.is_running, };
            return result;
        }

        // On macOS, use task_threads to enumerate
        const task = self.process.getTask() catch {
            const result = try allocator.alloc(types.ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main", .is_stopped = !self.process.is_running, };
            return result;
        };

        var threads_ptr: std.c.mach_port_array_t = undefined;
        var thread_count: std.c.mach_msg_type_number_t = undefined;
        const kr = std.c.task_threads(task, &threads_ptr, &thread_count);
        if (kr != 0) {
            const result = try allocator.alloc(types.ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main", .is_stopped = !self.process.is_running, };
            return result;
        }

        const result = try allocator.alloc(types.ThreadInfo, thread_count);
        for (0..thread_count) |i| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "thread-{d}", .{i + 1}) catch "thread";
            result[i] = .{
                .id = @intCast(i + 1),
                .name = try allocator.dupe(u8, if (i == 0) "main" else name),
                .is_stopped = !self.process.is_running,
            };
        }
        return result;
    }

    // ── Stack Trace ─────────────────────────────────────────────────

    fn engineStackTrace(ctx: *anyopaque, allocator: std.mem.Allocator, _: u32, start_frame: u32, levels: u32) anyerror![]const types.StackFrame {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const regs = try self.process.readRegisters();
        const all_frames = self.buildStackTrace(regs) catch return &.{};

        // Apply pagination: start_frame and levels
        if (start_frame == 0 and levels == 0) return all_frames;

        const start: usize = @min(start_frame, all_frames.len);
        const remaining = all_frames.len - start;
        const count: usize = if (levels > 0) @min(levels, remaining) else remaining;

        if (start == 0 and count == all_frames.len) return all_frames;

        // Return a slice copy so the caller owns it
        const result = try allocator.dupe(types.StackFrame, all_frames[start..][0..count]);
        self.allocator.free(all_frames);
        return result;
    }

    // ── Memory ──────────────────────────────────────────────────────

    fn engineReadMemory(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, size: u64) anyerror![]const u8 {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const data = if (self.core_dump) |*cd|
            try cd.readMemory(address, @intCast(size), allocator)
        else
            try self.process.readMemory(address, @intCast(size), allocator);
        // Convert to hex string
        const hex = try allocator.alloc(u8, data.len * 2);
        for (data, 0..) |byte, i| {
            const digits = "0123456789abcdef";
            hex[i * 2] = digits[byte >> 4];
            hex[i * 2 + 1] = digits[byte & 0x0f];
        }
        allocator.free(data);
        return hex;
    }

    fn engineWriteMemory(ctx: *anyopaque, _: std.mem.Allocator, address: u64, data: []const u8) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.core_dump != null) return error.NotSupported; // core dumps are read-only
        try self.process.writeMemory(address, data);
    }

    // ── Disassemble ─────────────────────────────────────────────────

    fn engineDisassemble(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, count: u32, _: ?i64, _: ?bool) anyerror![]const types.DisassembledInstruction {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const is_arm = builtin.cpu.arch == .aarch64;

        var instructions = std.ArrayListUnmanaged(types.DisassembledInstruction).empty;
        errdefer instructions.deinit(allocator);

        var addr = address;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const read_size: usize = if (is_arm) 4 else 16; // x86 instructions up to 15 bytes
            const bytes = self.process.readMemory(addr, read_size, allocator) catch break;
            defer allocator.free(bytes);

            // Substitute original bytes if a breakpoint is patched at this address
            if (self.bp_manager.findByAddress(addr)) |bp| {
                if (bp.enabled and bytes.len >= breakpoint_mod.bp_size) {
                    @memcpy(bytes[0..breakpoint_mod.bp_size], &bp.original_bytes);
                }
            }

            // Format address
            var addr_buf: [20]u8 = undefined;
            const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{addr}) catch break;

            if (is_arm) {
                if (bytes.len < 4) break;
                const word = std.mem.readInt(u32, bytes[0..4], .little);

                // Format bytes
                var bytes_buf: [12]u8 = undefined;
                const bytes_str = std.fmt.bufPrint(&bytes_buf, "{x:0>8}", .{word}) catch break;

                // Decode common ARM64 instructions
                const mnemonic = decodeArm64(word);

                try instructions.append(allocator, .{
                    .address = try allocator.dupe(u8, addr_str),
                    .instruction = try allocator.dupe(u8, mnemonic),
                    .instruction_bytes = try allocator.dupe(u8, bytes_str),
                });
                addr += 4;
            } else {
                // x86_64: variable length, basic decoding
                const decoded = decodeX86(bytes);

                // Format bytes as hex
                var bytes_buf: [32]u8 = undefined;
                var bpos: usize = 0;
                for (bytes[0..decoded.len]) |b| {
                    const digits = "0123456789abcdef";
                    if (bpos + 2 > bytes_buf.len) break;
                    bytes_buf[bpos] = digits[b >> 4];
                    bytes_buf[bpos + 1] = digits[b & 0x0f];
                    bpos += 2;
                }

                try instructions.append(allocator, .{
                    .address = try allocator.dupe(u8, addr_str),
                    .instruction = try allocator.dupe(u8, decoded.mnemonic),
                    .instruction_bytes = try allocator.dupe(u8, bytes_buf[0..bpos]),
                });
                addr += decoded.len;
            }
        }

        return try instructions.toOwnedSlice(allocator);
    }

    const DecodedX86 = struct { mnemonic: []const u8, len: u64 };

    fn decodeX86(bytes: []const u8) DecodedX86 {
        if (bytes.len == 0) return .{ .mnemonic = "???", .len = 1 };
        return switch (bytes[0]) {
            0xCC => .{ .mnemonic = "int3", .len = 1 },
            0xC3 => .{ .mnemonic = "ret", .len = 1 },
            0x90 => .{ .mnemonic = "nop", .len = 1 },
            0x55 => .{ .mnemonic = "push rbp", .len = 1 },
            0x50...0x54, 0x56, 0x57 => .{ .mnemonic = "push", .len = 1 },
            0x58...0x5f => .{ .mnemonic = "pop", .len = 1 },
            0xE8 => .{ .mnemonic = "call", .len = 5 },
            0xE9 => .{ .mnemonic = "jmp", .len = 5 },
            0xEB => .{ .mnemonic = "jmp short", .len = 2 },
            0x48 => blk: {
                if (bytes.len < 2) break :blk .{ .mnemonic = "rex.w", .len = 1 };
                break :blk switch (bytes[1]) {
                    0x89 => .{ .mnemonic = "mov", .len = 3 },
                    0x8B => .{ .mnemonic = "mov", .len = 3 },
                    0x83 => .{ .mnemonic = "sub/add", .len = 4 },
                    0x8D => .{ .mnemonic = "lea", .len = 3 },
                    else => .{ .mnemonic = "rex.w ...", .len = 2 },
                };
            },
            else => .{ .mnemonic = "???", .len = 1 },
        };
    }

    fn decodeArm64(word: u32) []const u8 {
        // NOP
        if (word == 0xD503201F) return "nop";
        // RET
        if (word == 0xD65F03C0) return "ret";
        // BRK #0
        if (word == 0xD4200000) return "brk #0";
        // BL (branch with link)
        if (word >> 26 == 0x25) return "bl";
        // B (unconditional branch)
        if (word >> 26 == 0x05) return "b";
        // STP (store pair)
        if ((word >> 22) & 0x1FF == 0x1A9) return "stp";
        // LDP (load pair)
        if ((word >> 22) & 0x1FF == 0x1A5) return "ldp";
        // ADD immediate
        if ((word >> 24) & 0x1F == 0x11) return "add";
        // SUB immediate
        if ((word >> 24) & 0x1F == 0x19) return "sub";
        // MOV (register)
        if ((word >> 24) & 0x1F == 0x15) return "mov";
        return "???";
    }

    // ── Function Breakpoints ────────────────────────────────────────

    fn engineSetFunctionBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8, condition: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.functions.len == 0) return error.NoDebugInfo;

        // Find function by name
        for (self.functions) |func| {
            if (std.mem.eql(u8, func.name, name)) {
                // Find first line entry after function prologue (first source line in body)
                // This skips the prologue so parameters are established when we stop
                var bp_addr = func.low_pc;
                var bp_line: u32 = 0;
                if (self.line_entries.len > 0) {
                    var best_addr: ?u64 = null;
                    var best_line: u32 = 0;
                    for (self.line_entries) |entry| {
                        if (entry.end_sequence) continue;
                        if (entry.address >= func.low_pc and
                            (func.high_pc == 0 or entry.address < func.high_pc))
                        {
                            if (best_addr == null or entry.address < best_addr.?) {
                                best_addr = entry.address;
                                best_line = entry.line;
                            }
                        }
                    }
                    if (best_addr) |addr| {
                        bp_addr = addr;
                        bp_line = best_line;
                    }
                }

                const bp_id = try self.bp_manager.setAtAddressEx(bp_addr, func.name, bp_line, condition);

                // Write trap instruction
                self.bp_manager.writeBreakpoint(bp_id, &self.process) catch |err| {
                    self.bp_manager.remove(bp_id) catch {};
                    return err;
                };

                return .{
                    .id = bp_id,
                    .verified = true,
                    .file = func.name,
                    .line = bp_line,
                    .condition = condition,
                };
            }
        }

        return error.FunctionNotFound;
    }

    // ── Exception Breakpoints ───────────────────────────────────────

    // ── Set Variable ─────────────────────────────────────────────────

    fn engineSetVariable(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.core_dump != null) return error.NotSupported; // core dumps are read-only
        const regs = try self.process.readRegisters();

        // Adjust registers for target frame if needed (sync GPR array for RegisterAdapter)
        var frame_regs = regs;
        if (frame_id > 0) {
            for (self.cached_stack_trace) |frame| {
                if (frame.id == frame_id) {
                    if (frame.fp != 0) {
                        frame_regs.fp = frame.fp;
                        if (builtin.cpu.arch == .aarch64) {
                            frame_regs.gprs[29] = frame.fp;
                        } else if (builtin.cpu.arch == .x86_64) {
                            frame_regs.gprs[6] = frame.fp;
                        }
                    }
                    if (frame.address != 0) frame_regs.pc = frame.address;
                    if (frame.sp != 0) {
                        frame_regs.sp = frame.sp;
                        if (builtin.cpu.arch == .aarch64) {
                            frame_regs.gprs[31] = frame.sp;
                        } else if (builtin.cpu.arch == .x86_64) {
                            frame_regs.gprs[7] = frame.sp;
                        }
                    }
                    break;
                }
            }
        }

        // Find debug binary
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return error.NoDebugInfo;
        };

        const info_data = debug_binary.getSectionData(debug_binary.sections.debug_info orelse return error.NoDebugInfo) orelse return error.NoDebugInfo;
        const abbrev_data = debug_binary.getSectionData(debug_binary.sections.debug_abbrev orelse return error.NoDebugInfo) orelse return error.NoDebugInfo;
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null;

        // Use target frame's PC for variable lookup
        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            frame_regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            frame_regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        const extra_sections = parser.ExtraSections{
            .debug_str_offsets = str_offsets_data,
            .debug_addr = addr_data,
            .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
            .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
            .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
            .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
        };

        var scoped = try parser.parseScopedVariables(
            info_data,
            abbrev_data,
            str_data,
            extra_sections,
            dwarf_pc,
            allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        );
        defer parser.freeScopedVariables(scoped, allocator);

        // Build adapters using target frame registers
        var reg_adapter = RegisterAdapter{ .regs = frame_regs };
        const reg_provider = reg_adapter.provider();
        var mem_adapter = MemoryAdapter{ .process = &self.process, .allocator = allocator };
        const mem_reader = mem_adapter.reader();

        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(frame_regs) });
            break :blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Find the variable
        for (scoped.variables) |v| {
            if (!std.mem.eql(u8, v.name, name)) continue;
            if (v.location_expr.len == 0) return error.VariableOptimizedOut;

            const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);
            const addr_to_write: u64 = switch (loc) {
                .address => |addr| addr,
                .value, .register, .empty, .implicit_pointer, .composite => return error.CannotWriteVariable,
            };

            // Parse the value string to an integer
            const int_val = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;

            // Write based on variable size
            const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 4;
            var raw: [8]u8 = undefined;
            std.mem.writeInt(i64, &raw, int_val, .little);
            try self.process.writeMemory(addr_to_write, raw[0..size]);

            // Return new value
            const result_str = try allocator.dupe(u8, value);
            const type_owned = try allocator.dupe(u8, v.type_name);
            return .{ .result = result_str, .@"type" = type_owned, .result_allocated = true };
        }

        // Variable not found at current PC — try nearest line entry PC
        // (handles DWARF location list gaps after stepping)
        if (self.line_entries.len > 0) {
            const best_addr = self.findNearestDwarfLineAddress(dwarf_pc);
            if (best_addr != 0 and best_addr != dwarf_pc) {
                parser.freeScopedVariables(scoped, allocator);
                scoped = parser.parseScopedVariables(
                    info_data,
                    abbrev_data,
                    str_data,
                    extra_sections,
                    best_addr,
                    allocator,
                    if (self.abbrev_cache) |*ac| ac else null,
                    self.cuHintForPC(best_addr),
                    if (self.type_die_cache) |*tdc| tdc else null,
                ) catch return error.VariableNotFound;

                for (scoped.variables) |v| {
                    if (!std.mem.eql(u8, v.name, name)) continue;
                    if (v.location_expr.len == 0) return error.VariableOptimizedOut;

                    const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);
                    const addr_to_write: u64 = switch (loc) {
                        .address => |addr| addr,
                        .value, .register, .empty, .implicit_pointer, .composite => return error.CannotWriteVariable,
                    };

                    const int_val = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;
                    const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 4;
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(i64, &raw, int_val, .little);
                    try self.process.writeMemory(addr_to_write, raw[0..size]);

                    const result_str = try allocator.dupe(u8, value);
                    const type_owned = try allocator.dupe(u8, v.type_name);
                    return .{ .result = result_str, .@"type" = type_owned, .result_allocated = true };
                }
            }
        }

        return error.VariableNotFound;
    }

    // ── Goto ────────────────────────────────────────────────────────

    fn engineGoto(ctx: *anyopaque, _: std.mem.Allocator, file: []const u8, line: u32) anyerror!StopState {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.line_entries.len == 0) return error.NoDebugInfo;

        // Find address for target line, filtering by file if provided.
        // When a file is specified, prefer exact/suffix matches over basename-only
        // matches to avoid resolving to wrong files (e.g. Go runtime files).
        var target_addr: ?u64 = null;
        var best_match_quality: u8 = 0;
        for (self.line_entries) |entry| {
            if (entry.end_sequence) continue;
            if (entry.line != line or !entry.is_stmt) continue;
            if (file.len > 0 and self.file_entries.len > 0) {
                const entry_file = if (entry.file_index < self.file_entries.len)
                    self.file_entries[entry.file_index].name
                else
                    "";
                const quality = breakpoint_mod.fileMatchQuality(file, entry_file);
                if (quality == 0) continue;
                if (quality > best_match_quality) {
                    best_match_quality = quality;
                    target_addr = entry.address;
                    if (quality == 3) break; // exact match, can't do better
                }
            } else {
                target_addr = entry.address;
                break;
            }
        }

        const addr = target_addr orelse return error.NoAddressForLine;

        // Set PC to new address
        var regs = try self.process.readRegisters();
        regs.pc = addr;
        try self.process.writeRegisters(regs);

        // Resolve location
        const loc = if (self.file_entries.len > 0)
            parser.resolveAddress(self.line_entries, self.file_entries, addr)
        else
            null;

        return .{
            .stop_reason = .step,
            .location = if (loc) |l| .{
                .file = l.file,
                .line = l.line,
            } else null,
        };
    }

    fn engineSetExceptionBreakpoints(ctx: *anyopaque, _: std.mem.Allocator, filters: []const []const u8) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        // Reset all exception signals
        @memset(&self.exception_signals, false);

        for (filters) |filter| {
            const sig = parseSignalName(filter);
            if (sig > 0 and sig < 32) {
                self.exception_signals[sig] = true;
            }
        }
    }

    fn isFatalSignal(sig: u8) bool {
        return switch (sig) {
            4, 6, 8, 10, 11 => true, // SIGILL, SIGABRT, SIGFPE, SIGBUS, SIGSEGV
            else => false,
        };
    }

    /// Returns true if the function name is a Go runtime trampoline that should
    /// be stepped through transparently. These include morestack (stack growth),
    /// gogo (goroutine resume), and other runtime internals that sit between
    /// user function calls.
    fn isRuntimeTrampoline(name: []const u8) bool {
        if (std.mem.startsWith(u8, name, "runtime.morestack")) return true;
        if (std.mem.startsWith(u8, name, "runtime.newstack")) return true;
        if (std.mem.startsWith(u8, name, "runtime.gogo")) return true;
        if (std.mem.startsWith(u8, name, "runtime.systemstack")) return true;
        if (std.mem.startsWith(u8, name, "runtime.mcall")) return true;
        return false;
    }

    fn signalName(sig: u8) []const u8 {
        return switch (sig) {
            4 => "SIGILL",
            6 => "SIGABRT",
            8 => "SIGFPE",
            10 => "SIGBUS",
            11 => "SIGSEGV",
            13 => "SIGPIPE",
            else => "SIGNAL",
        };
    }

    fn parseSignalName(name: []const u8) u8 {
        if (std.mem.eql(u8, name, "SIGSEGV")) return 11;
        if (std.mem.eql(u8, name, "SIGFPE")) return 8;
        if (std.mem.eql(u8, name, "SIGBUS")) return 10;
        if (std.mem.eql(u8, name, "SIGABRT")) return 6;
        if (std.mem.eql(u8, name, "SIGILL")) return 4;
        if (std.mem.eql(u8, name, "SIGPIPE")) return 13;
        // Try parsing as a number
        return std.fmt.parseInt(u8, name, 10) catch 0;
    }

    // ── Attach ──────────────────────────────────────────────────────

    fn engineAttach(ctx: *anyopaque, _: std.mem.Allocator, pid: u32) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        try self.process.attach(@intCast(pid));
        self.launched = true;

        // Try to find binary path from /proc or lsof for debug info
        // For now, debug info loading requires explicit program path
    }

    // ── Core Dump ──────────────────────────────────────────────────

    fn engineLoadCore(ctx: *anyopaque, allocator: std.mem.Allocator, core_path: []const u8, executable_path: ?[]const u8) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        self.core_dump = try core_dump_mod.CoreDump.load(allocator, core_path);
        self.launched = true;
        if (executable_path) |exe| {
            self.program_path = try allocator.dupe(u8, exe);
            self.loadDebugInfo(exe) catch {};
            // No ASLR slide for core dumps — addresses in core match the process at crash time
        }
    }

    // ── Scopes ──────────────────────────────────────────────────────

    fn engineScopes(ctx: *anyopaque, allocator: std.mem.Allocator, _: u32) anyerror![]const types.Scope {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        const regs = try self.process.readRegisters();
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return error.NoDebugInfo;
        };

        const info_data = debug_binary.getSectionData(debug_binary.sections.debug_info orelse return error.NoDebugInfo) orelse return error.NoDebugInfo;
        const abbrev_data = debug_binary.getSectionData(debug_binary.sections.debug_abbrev orelse return error.NoDebugInfo) orelse return error.NoDebugInfo;
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null;

        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        const scoped = parser.parseScopedVariables(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
            },
            dwarf_pc,
            allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch return error.NoDebugInfo;
        defer parser.freeScopedVariables(scoped, allocator);

        // Count locals and arguments
        var local_count: u32 = 0;
        var arg_count: u32 = 0;
        for (scoped.variables) |v| {
            if (v.scope == .argument) {
                arg_count += 1;
            } else {
                local_count += 1;
            }
        }

        var scopes = std.ArrayListUnmanaged(types.Scope).empty;
        errdefer scopes.deinit(allocator);

        if (local_count > 0) {
            try scopes.append(allocator, .{
                .name = try allocator.dupe(u8, "Locals"),
                .variables_reference = 1,
                .expensive = false,
            });
        }
        if (arg_count > 0) {
            try scopes.append(allocator, .{
                .name = try allocator.dupe(u8, "Arguments"),
                .variables_reference = 2,
                .expensive = false,
            });
        }

        return try scopes.toOwnedSlice(allocator);
    }

    // ── Capabilities ────────────────────────────────────────────────

    fn engineCapabilities(_: *anyopaque) types.DebugCapabilities {
        return .{
            .supports_conditional_breakpoints = true,
            .supports_hit_conditional_breakpoints = true,
            .supports_log_points = true,
            .supports_function_breakpoints = true,
            .supports_data_breakpoints = (builtin.cpu.arch == .aarch64),
            .supports_step_back = false,
            .supports_restart_frame = false,
            .supports_goto_targets = true,
            .supports_completions = true,
            .supports_modules = true,
            .supports_set_variable = true,
            .supports_set_expression = true,
            .supports_terminate = true,
            .supports_read_memory = true,
            .supports_write_memory = true,
            .supports_disassemble = true,
            .supports_instruction_breakpoints = true,
            .supports_stepping_granularity = true,
            .supports_cancel_request = true,
            .supports_terminate_threads = true,
            .supports_breakpoint_locations = true,
            .supports_step_in_targets = true,
            .supports_evaluate_for_hovers = true,
            .supports_value_formatting = true,
            .supports_loaded_sources = true,
            .supports_restart_request = true,
            .supports_single_thread_execution_requests = true,
            .supports_exception_options = true,
            .support_terminate_debuggee = true,
            .supports_clipboard_context = true,
        };
    }

    // ── Completions ────────────────────────────────────────────────

    fn engineCompletions(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8, _: u32, _: ?u32) anyerror![]const types.CompletionItem {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        var items = std.ArrayListUnmanaged(types.CompletionItem).empty;
        errdefer items.deinit(allocator);

        // Match variable names from current scope
        const regs = self.process.readRegisters() catch return try items.toOwnedSlice(allocator);

        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return try items.toOwnedSlice(allocator);
        };

        const info_data = debug_binary.getSectionData(debug_binary.sections.debug_info orelse return try items.toOwnedSlice(allocator)) orelse return try items.toOwnedSlice(allocator);
        const abbrev_data = debug_binary.getSectionData(debug_binary.sections.debug_abbrev orelse return try items.toOwnedSlice(allocator)) orelse return try items.toOwnedSlice(allocator);
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;
        const str_offsets_data = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null;
        const addr_data = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null;

        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        const scoped = parser.parseScopedVariables(
            info_data, abbrev_data, str_data,
            .{
                .debug_str_offsets = str_offsets_data,
                .debug_addr = addr_data,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
            },
            dwarf_pc, allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch return try items.toOwnedSlice(allocator);
        defer parser.freeScopedVariables(scoped, allocator);

        // Match variables
        for (scoped.variables) |v| {
            if (v.name.len > 0 and (text.len == 0 or std.mem.startsWith(u8, v.name, text))) {
                const scope_str: []const u8 = if (v.scope == .argument) "argument" else "variable";
                try items.append(allocator, .{
                    .label = try allocator.dupe(u8, v.name),
                    .text = try allocator.dupe(u8, v.name),
                    .item_type = try allocator.dupe(u8, scope_str),
                });
            }
        }

        // Match function names
        for (self.functions) |func| {
            if (func.name.len > 0 and (text.len == 0 or std.mem.startsWith(u8, func.name, text))) {
                try items.append(allocator, .{
                    .label = try allocator.dupe(u8, func.name),
                    .text = try allocator.dupe(u8, func.name),
                    .item_type = try allocator.dupe(u8, "function"),
                });
            }
        }

        return try items.toOwnedSlice(allocator);
    }

    // ── Modules ─────────────────────────────────────────────────────

    fn engineModules(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const types.Module {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        var mods = std.ArrayListUnmanaged(types.Module).empty;
        errdefer mods.deinit(allocator);

        if (self.program_path) |path| {
            const has_debug = self.binary != null and self.binary.?.sections.debug_info != null;
            const has_dsym = self.dsym_binary != null;
            const sym_status: []const u8 = if (has_dsym) "dSYM loaded" else if (has_debug) "debug info loaded" else "no debug info";

            try mods.append(allocator, .{
                .id = try allocator.dupe(u8, "main"),
                .name = try allocator.dupe(u8, std.fs.path.basename(path)),
                .path = try allocator.dupe(u8, path),
                .symbol_status = try allocator.dupe(u8, sym_status),
            });
        }

        return try mods.toOwnedSlice(allocator);
    }

    // ── Loaded Sources ──────────────────────────────────────────────

    fn engineLoadedSources(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const types.LoadedSource {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        var sources = std.ArrayListUnmanaged(types.LoadedSource).empty;
        errdefer sources.deinit(allocator);

        // Return source files from parsed debug line info
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_line != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_line != null) break :blk bin;
            }
            return try sources.toOwnedSlice(allocator);
        };

        const line_data = debug_binary.getSectionData(debug_binary.sections.debug_line orelse return try sources.toOwnedSlice(allocator)) orelse return try sources.toOwnedSlice(allocator);
        const line_str_data = if (debug_binary.sections.debug_line_str) |s| debug_binary.getSectionData(s) else null;

        const result = parser.parseLineProgramWithFilesEx(line_data, allocator, line_str_data) catch return try sources.toOwnedSlice(allocator);
        defer allocator.free(result.line_entries);
        defer allocator.free(result.file_entries);

        // Deduplicate file entries
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(allocator);

        for (result.file_entries) |fe| {
            if (fe.name.len == 0) continue;
            const gop = try seen.getOrPut(allocator, fe.name);
            if (gop.found_existing) continue;

            try sources.append(allocator, .{
                .name = try allocator.dupe(u8, std.fs.path.basename(fe.name)),
                .path = try allocator.dupe(u8, fe.name),
            });
        }

        return try sources.toOwnedSlice(allocator);
    }

    // ── Step In Targets ──────────────────────────────────────────────

    fn engineStepInTargets(ctx: *anyopaque, allocator: std.mem.Allocator, _: u32) anyerror![]const types.StepInTarget {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const regs = try self.process.readRegisters();
        const pc = regs.pc;

        // Find current line's address range from line_entries
        const current_line = self.getLineForPC(pc) orelse return &.{};
        var line_start: u64 = pc;
        var line_end: u64 = pc;

        // Find all addresses that belong to the current line
        for (self.line_entries) |entry| {
            if (entry.end_sequence) continue;
            if (entry.line == current_line and entry.address >= pc) {
                if (entry.address < line_start or line_start == pc) line_start = entry.address;
            }
        }
        line_start = pc; // Always start from current PC

        // Find the next line's first address as the end
        if (self.findNextLineAddress(pc)) |next_addr| {
            line_end = next_addr;
        } else {
            // If no next line, scan a small range
            line_end = pc + 64;
        }

        if (line_end <= line_start) return &.{};

        var targets = std.ArrayListUnmanaged(types.StepInTarget).empty;
        errdefer targets.deinit(allocator);

        const is_arm = builtin.cpu.arch == .aarch64;
        var next_id: u32 = 1;
        var addr = line_start;

        while (addr < line_end) {
            if (is_arm) {
                const bytes = self.process.readMemory(addr, 4, allocator) catch break;
                defer allocator.free(bytes);
                if (bytes.len < 4) break;

                // Substitute original bytes if breakpoint patched at this address
                if (self.bp_manager.findByAddress(addr)) |bp| {
                    if (bp.enabled and bytes.len >= breakpoint_mod.bp_size) {
                        @memcpy(bytes[0..breakpoint_mod.bp_size], &bp.original_bytes);
                    }
                }

                const word = std.mem.readInt(u32, bytes[0..4], .little);

                // BL (branch with link) — opcode: top 6 bits = 100101
                if (word >> 26 == 0x25) {
                    // Extract signed 26-bit immediate, shifted left by 2 to form byte offset
                    const raw_imm: u32 = word & 0x03FFFFFF;
                    // Sign-extend: shift left 6 to put sign bit at bit 31, then arithmetic shift right 4
                    const sign_extended: i32 = @as(i32, @bitCast(raw_imm << 6)) >> 4;
                    const target_addr: u64 = @bitCast(@as(i64, @bitCast(addr)) +% @as(i64, sign_extended));
                    const func_name = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, target_addr) else "<unknown>";
                    if (!std.mem.eql(u8, func_name, "<unknown>")) {
                        try targets.append(allocator, .{
                            .id = next_id,
                            .label = try allocator.dupe(u8, func_name),
                        });
                        next_id += 1;
                    }
                }
                // BLR (branch with link to register) — opcode: 1101011000111111xxxxxxx00000xxxxx
                // Encoding: 1101 0110 0011 1111 0000 00xx xxx0 0000
                if ((word & 0xFFFFFC1F) == 0xD63F0000) {
                    // Target is in a register — we can try to read it
                    const rn = (word >> 5) & 0x1F;
                    const reg_val = regs.gprs[rn];
                    if (reg_val != 0) {
                        const func_name = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, reg_val) else "<unknown>";
                        if (!std.mem.eql(u8, func_name, "<unknown>")) {
                            try targets.append(allocator, .{
                                .id = next_id,
                                .label = try allocator.dupe(u8, func_name),
                            });
                            next_id += 1;
                        }
                    }
                }
                addr += 4;
            } else {
                // x86_64: read up to 16 bytes for instruction decoding
                const bytes = self.process.readMemory(addr, 16, allocator) catch break;
                defer allocator.free(bytes);
                if (bytes.len == 0) break;

                // Substitute original bytes if breakpoint patched
                if (self.bp_manager.findByAddress(addr)) |bp| {
                    if (bp.enabled and bytes.len >= breakpoint_mod.bp_size) {
                        @memcpy(bytes[0..breakpoint_mod.bp_size], &bp.original_bytes);
                    }
                }

                // Check for CALL instructions (E8 rel32 or FF /2 indirect)
                if (bytes[0] == 0xE8 and bytes.len >= 5) {
                    // Direct CALL rel32
                    const rel: i32 = @bitCast(std.mem.readInt(u32, bytes[1..5], .little));
                    const target_addr: u64 = @bitCast(@as(i64, @intCast(@as(i64, @bitCast(addr)))) + @as(i64, rel) + 5);
                    const func_name = if (self.functions.len > 0) unwind.findFunctionForPC(self.functions, target_addr) else "<unknown>";
                    if (!std.mem.eql(u8, func_name, "<unknown>")) {
                        try targets.append(allocator, .{
                            .id = next_id,
                            .label = try allocator.dupe(u8, func_name),
                        });
                        next_id += 1;
                    }
                    addr += 5;
                    continue;
                }
                // Skip other instructions — advance by 1 byte (basic heuristic)
                addr += 1;
            }
        }

        return try targets.toOwnedSlice(allocator);
    }

    // ── Data Breakpoints ────────────────────────────────────────────

    fn engineDataBreakpointInfo(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, frame_id: ?u32) anyerror!types.DataBreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (builtin.cpu.arch != .aarch64) return error.NotSupported;

        const regs = try self.process.readRegisters();

        // Adjust registers for target frame
        var frame_regs = regs;
        if (frame_id) |fid| {
            if (fid > 0) {
                for (self.cached_stack_trace) |frame| {
                    if (frame.id == fid) {
                        if (frame.fp != 0) frame_regs.fp = frame.fp;
                        if (frame.address != 0) frame_regs.pc = frame.address;
                        if (frame.sp != 0) frame_regs.sp = frame.sp;
                        break;
                    }
                }
            }
        }

        // Find the variable using DWARF info
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_info != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_info != null) break :blk bin;
            }
            return error.NoDebugInfo;
        };

        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            frame_regs.pc -% @as(u64, @intCast(self.aslr_slide))
        else
            frame_regs.pc +% @as(u64, @intCast(-self.aslr_slide));

        const info_data = debug_binary.getSectionData(debug_binary.sections.debug_info orelse return error.NoDebugInfo) orelse return error.NoDebugInfo;
        const abbrev_data = debug_binary.getSectionData(debug_binary.sections.debug_abbrev orelse return error.NoDebugInfo) orelse return error.NoDebugInfo;
        const str_data = if (debug_binary.sections.debug_str) |s| debug_binary.getSectionData(s) else null;

        const scoped = try parser.parseScopedVariables(
            info_data,
            abbrev_data,
            str_data,
            .{
                .debug_str_offsets = if (debug_binary.sections.debug_str_offsets) |s| debug_binary.getSectionData(s) else null,
                .debug_addr = if (debug_binary.sections.debug_addr) |s| debug_binary.getSectionData(s) else null,
                .debug_ranges = if (debug_binary.sections.debug_ranges) |s| debug_binary.getSectionData(s) else null,
                .debug_rnglists = if (debug_binary.sections.debug_rnglists) |s| debug_binary.getSectionData(s) else null,
                .debug_loc = if (debug_binary.sections.debug_loc) |s| debug_binary.getSectionData(s) else null,
                .debug_loclists = if (debug_binary.sections.debug_loclists) |s| debug_binary.getSectionData(s) else null,
            },
            dwarf_pc,
            allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        );
        defer parser.freeScopedVariables(scoped, allocator);

        var reg_adapter = RegisterAdapter{ .regs = frame_regs };
        const reg_provider = reg_adapter.provider();
        var mem_adapter = MemoryAdapter{ .process = &self.process, .allocator = allocator };
        const mem_reader = mem_adapter.reader();

        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(frame_regs) });
            break :blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Find the variable's memory address
        for (scoped.variables) |v| {
            if (!std.mem.eql(u8, v.name, name)) continue;
            if (v.location_expr.len == 0) continue;

            const loc = location.evalLocationWithMemory(v.location_expr, reg_provider, frame_base, mem_reader);
            switch (loc) {
                .address => |addr| {
                    const size: u8 = if (v.type_byte_size > 0) @intCast(@min(v.type_byte_size, 8)) else 4;
                    // Build data_id as "address:size" string
                    const data_id = try std.fmt.allocPrint(allocator, "0x{x}:{d}", .{ addr, size });
                    const desc = try std.fmt.allocPrint(allocator, "{s} at 0x{x}", .{ name, addr });
                    const access_types = try allocator.alloc(types.DataBreakpointAccessType, 3);
                    access_types[0] = .read;
                    access_types[1] = .write;
                    access_types[2] = .readWrite;
                    return .{
                        .data_id = data_id,
                        .description = desc,
                        .access_types = access_types,
                    };
                },
                else => return error.VariableNotInMemory,
            }
        }

        return error.VariableNotFound;
    }

    fn engineSetDataBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, data_id: []const u8, access_type: types.DataBreakpointAccessType) anyerror!types.BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (builtin.cpu.arch != .aarch64) return error.NotSupported;

        // Parse data_id format: "0xADDRESS:SIZE"
        const colon_pos = std.mem.indexOf(u8, data_id, ":") orelse return error.InvalidDataId;
        const addr_str = data_id[0..colon_pos];
        const size_str = data_id[colon_pos + 1 ..];

        // Parse address (skip "0x" prefix)
        const addr_start: usize = if (std.mem.startsWith(u8, addr_str, "0x")) 2 else 0;
        const address = std.fmt.parseInt(u64, addr_str[addr_start..], 16) catch return error.InvalidDataId;
        const size = std.fmt.parseInt(u8, size_str, 10) catch return error.InvalidDataId;

        // Convert access type to hardware encoding
        const hw_access: u8 = switch (access_type) {
            .read => 1,
            .write => 2,
            .readWrite => 3,
        };

        // Set hardware watchpoint
        const slot = try self.process.setHardwareWatchpoint(address, size, hw_access);
        _ = allocator;

        // Track watchpoint state for hit detection, step-past, and removal
        self.hw_watchpoints[slot] = .{
            .active = true,
            .id = slot + 1000,
            .address = address,
            .size = size,
            .access_type = @intCast(hw_access),
        };

        return .{
            .id = slot + 1000, // Offset to distinguish from software breakpoints
            .verified = true,
            .file = "",
            .line = 0,
        };
    }

    // ── Restart Frame ──────────────────────────────────────────────

    fn engineRestartFrame(_: *anyopaque, _: std.mem.Allocator, _: u32) anyerror!void {
        // Frame restart is not supported for native DWARF debugging
        return error.NotSupported;
    }

    // ── Cancel ──────────────────────────────────────────────────────

    fn engineCancel(_: *anyopaque, _: std.mem.Allocator, _: ?u32, _: ?[]const u8) anyerror!void {
        // No-op: the native engine has no async operations to cancel.
    }

    // ── Terminate Threads ───────────────────────────────────────────

    fn engineTerminateThreads(_: *anyopaque, _: std.mem.Allocator, _: []const u32) anyerror!void {
        // No-op: the native engine manages threads via ptrace; individual
        // thread termination is not meaningful in this context.
    }

    // ── Source ───────────────────────────────────────────────────────

    fn engineSource(ctx: *anyopaque, allocator: std.mem.Allocator, source_ref: u32) anyerror![]const u8 {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        // Source references map to file entries from DWARF debug line info
        // Get file entries from the debug binary
        const debug_binary: *const binary_macho.MachoBinary = blk: {
            if (self.dsym_binary) |*dsym| {
                if (dsym.sections.debug_line != null) break :blk dsym;
            }
            if (self.binary) |*bin| {
                if (bin.sections.debug_line != null) break :blk bin;
            }
            return error.NotSupported;
        };

        const line_data = debug_binary.getSectionData(debug_binary.sections.debug_line orelse return error.NotSupported) orelse return error.NotSupported;
        const line_str_data = if (debug_binary.sections.debug_line_str) |s| debug_binary.getSectionData(s) else null;

        const result = parser.parseLineProgramWithFilesEx(line_data, allocator, line_str_data) catch return error.NotSupported;
        defer allocator.free(result.line_entries);
        defer allocator.free(result.file_entries);

        // source_ref is 1-based index into file entries
        if (source_ref == 0 or source_ref > result.file_entries.len) return error.InvalidSourceReference;
        const fe = result.file_entries[source_ref - 1];
        if (fe.name.len == 0) return error.InvalidSourceReference;

        // Read the file from disk
        const file = std.fs.openFileAbsolute(fe.name, .{}) catch |err| {
            // Try relative to cwd
            const cwd_file = std.fs.cwd().openFile(fe.name, .{}) catch return err;
            defer cwd_file.close();
            return try cwd_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        };
        defer file.close();
        return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    }

    // ── Set Expression ──────────────────────────────────────────────

    fn engineSetExpression(ctx: *anyopaque, allocator: std.mem.Allocator, expression: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult {
        // For native DWARF, treat the expression as a variable name and delegate to setVariable
        return engineSetVariable(ctx, allocator, expression, value, frame_id);
    }

    // ── Terminate ───────────────────────────────────────────────────

    fn engineTerminate(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        // Use process.kill() which handles ptrace-stopped processes correctly.
        // SIGTERM can't be delivered to a ptrace-stopped process on macOS,
        // causing the same deadlock as SIGKILL without PT_KILL.
        try self.process.kill();
        self.launched = false;
    }

    // ── Exception Info ──────────────────────────────────────────────

    fn engineExceptionInfo(ctx: *anyopaque, _: std.mem.Allocator, _: u32) anyerror!types.ExceptionInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        // Return info about the last exception signal
        if (self.process.pid == null) return error.NoProcess;

        // For native debugging, exceptions are signals (SIGSEGV, SIGFPE, etc.)
        // We return a generic exception info based on what we know
        return .{
            .@"type" = "signal",
            .message = "Process stopped by signal",
        };
    }

    // ── Read Registers ──────────────────────────────────────────────

    fn engineReadRegisters(ctx: *anyopaque, allocator: std.mem.Allocator, _: u32) anyerror![]const types.RegisterInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        const regs = if (self.core_dump) |*cd|
            cd.readRegisters()
        else
            try self.process.readRegisters();
        const is_arm = builtin.cpu.arch == .aarch64;

        var items = std.ArrayListUnmanaged(types.RegisterInfo).empty;
        errdefer items.deinit(allocator);

        // Program counter, stack pointer, frame pointer
        try items.append(allocator, .{ .name = if (is_arm) "pc" else "rip", .value = regs.pc });
        try items.append(allocator, .{ .name = if (is_arm) "sp" else "rsp", .value = regs.sp });
        try items.append(allocator, .{ .name = if (is_arm) "fp" else "rbp", .value = regs.fp });
        try items.append(allocator, .{ .name = "flags", .value = regs.flags });

        if (is_arm) {
            // ARM64: x0-x28, fp(x29), lr(x30)
            for (0..29) |i| {
                var buf: [4]u8 = undefined;
                const name = std.fmt.bufPrint(&buf, "x{d}", .{i}) catch "x?";
                try items.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = regs.gprs[i] });
            }
            try items.append(allocator, .{ .name = "lr", .value = regs.gprs[30] });
        } else {
            // x86_64: rax, rdx, rcx, rbx, rsi, rdi, r8-r15
            const x86_names = [_][]const u8{ "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
            for (x86_names, 0..) |name, i| {
                try items.append(allocator, .{ .name = name, .value = regs.gprs[i] });
            }
        }

        // Append floating point / SIMD registers when available
        if (self.process.readFloatRegisters()) |fp_regs| {
            for (0..fp_regs.count) |i| {
                // Low 64 bits
                var lo_buf: [12]u8 = undefined;
                const lo_name = if (fp_regs.is_arm)
                    std.fmt.bufPrint(&lo_buf, "v{d}_lo", .{i}) catch "v?_lo"
                else
                    std.fmt.bufPrint(&lo_buf, "xmm{d}_lo", .{i}) catch "xmm?_lo";
                try items.append(allocator, .{
                    .name = try allocator.dupe(u8, lo_name),
                    .value = fp_regs.regs[i][0],
                });

                // High 64 bits
                var hi_buf: [12]u8 = undefined;
                const hi_name = if (fp_regs.is_arm)
                    std.fmt.bufPrint(&hi_buf, "v{d}_hi", .{i}) catch "v?_hi"
                else
                    std.fmt.bufPrint(&hi_buf, "xmm{d}_hi", .{i}) catch "xmm?_hi";
                try items.append(allocator, .{
                    .name = try allocator.dupe(u8, hi_name),
                    .value = fp_regs.regs[i][1],
                });
            }
        } else |_| {
            // FP register reading not available — skip silently
        }

        return try items.toOwnedSlice(allocator);
    }

    // ── Stop ────────────────────────────────────────────────────────

    fn engineStop(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        try self.process.kill();
        self.launched = false;
    }

    fn engineGetPid(ctx: *anyopaque) ?std.posix.pid_t {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        return self.process.pid;
    }

    // ── Goto Targets ──────────────────────────────────────────────

    fn engineGotoTargets(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror![]const types.GotoTarget {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (self.line_entries.len == 0) return &.{};

        var targets = std.ArrayListUnmanaged(types.GotoTarget).empty;
        errdefer targets.deinit(allocator);

        var next_id: u32 = 1;
        for (self.line_entries) |entry| {
            if (entry.end_sequence) continue;
            if (entry.line == line and entry.is_stmt) {
                // Filter by file if provided
                if (file.len > 0 and self.file_entries.len > 0) {
                    const entry_file = if (entry.file_index < self.file_entries.len)
                        self.file_entries[entry.file_index].name
                    else
                        "";
                    if (!breakpoint_mod.filePathsMatch(file, entry_file)) continue;
                }
                const label = try std.fmt.allocPrint(allocator, "Line {d}", .{entry.line});
                try targets.append(allocator, .{
                    .id = next_id,
                    .label = label,
                    .line = entry.line,
                });
                next_id += 1;
                break; // One target per matching line
            }
        }

        return try targets.toOwnedSlice(allocator);
    }

    // ── Find Symbol ────────────────────────────────────────────────

    fn engineFindSymbol(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const types.SymbolInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        var symbols = std.ArrayListUnmanaged(types.SymbolInfo).empty;
        errdefer symbols.deinit(allocator);

        // Try .debug_names accelerated lookup first (O(1) hash-based)
        if (self.debug_names_index) |*idx| {
            const entries = idx.lookup(name, allocator) catch &.{};
            defer if (entries.len > 0) allocator.free(entries);

            if (entries.len > 0) {
                for (entries) |entry| {
                    const kind_str: []const u8 = switch (entry.tag) {
                        0x2e => "function", // DW_TAG_subprogram
                        0x34 => "variable", // DW_TAG_variable
                        0x13 => "struct", // DW_TAG_structure_type
                        0x04 => "enum", // DW_TAG_enumeration_type
                        0x16 => "typedef", // DW_TAG_typedef
                        0x17 => "union", // DW_TAG_union_type
                        0x39 => "namespace", // DW_TAG_namespace
                        0x02 => "class", // DW_TAG_class_type
                        else => "symbol",
                    };

                    // Try to resolve file/line from the DIE offset via line entries
                    var file_name: []const u8 = "";
                    var line_num: ?u32 = null;

                    // Search functions for matching low_pc to get file/line
                    for (self.functions) |func| {
                        if (std.mem.eql(u8, func.name, name)) {
                            if (func.low_pc > 0) {
                                for (self.line_entries) |le| {
                                    if (le.address == func.low_pc and !le.end_sequence) {
                                        line_num = le.line;
                                        if (self.file_entries.len > 0 and le.file_index < self.file_entries.len) {
                                            file_name = self.file_entries[le.file_index].name;
                                        }
                                        break;
                                    }
                                }
                            }
                            break;
                        }
                    }

                    try symbols.append(allocator, .{
                        .name = try allocator.dupe(u8, name),
                        .kind = try allocator.dupe(u8, kind_str),
                        .file = if (file_name.len > 0) try allocator.dupe(u8, file_name) else "",
                        .line = line_num,
                    });
                }
                return try symbols.toOwnedSlice(allocator);
            }
        }

        // Fallback: linear scan through function names (substring match)
        for (self.functions) |func| {
            if (func.name.len > 0 and std.mem.indexOf(u8, func.name, name) != null) {
                // Resolve file from line entries
                var file_name: []const u8 = "";
                var line_num: ?u32 = null;
                if (func.low_pc > 0) {
                    for (self.line_entries) |entry| {
                        if (entry.address == func.low_pc and !entry.end_sequence) {
                            line_num = entry.line;
                            if (self.file_entries.len > 0 and entry.file_index < self.file_entries.len) {
                                file_name = self.file_entries[entry.file_index].name;
                            }
                            break;
                        }
                    }
                }

                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, func.name),
                    .kind = try allocator.dupe(u8, "function"),
                    .file = if (file_name.len > 0) try allocator.dupe(u8, file_name) else "",
                    .line = line_num,
                });
            }
        }

        return try symbols.toOwnedSlice(allocator);
    }

    // ── Instruction Breakpoints ────────────────────────────────────────

    fn engineSetInstructionBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator, breakpoints: []const InstructionBreakpoint) anyerror![]const types.BreakpointInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (!self.launched) return error.NotLaunched;

        var results = std.ArrayListUnmanaged(types.BreakpointInfo).empty;
        errdefer results.deinit(allocator);

        for (breakpoints) |bp| {
            const bp_id = self.bp_manager.setInstructionBreakpoint(bp) catch {
                try results.append(allocator, .{
                    .id = 0,
                    .verified = false,
                    .file = "",
                    .line = 0,
                });
                continue;
            };

            // Write trap instruction to process memory
            self.bp_manager.writeBreakpoint(bp_id, &self.process) catch {
                self.bp_manager.remove(bp_id) catch {};
                try results.append(allocator, .{
                    .id = 0,
                    .verified = false,
                    .file = "",
                    .line = 0,
                });
                continue;
            };

            try results.append(allocator, .{
                .id = bp_id,
                .verified = true,
                .file = "",
                .line = 0,
            });
        }

        return try results.toOwnedSlice(allocator);
    }

    // ── Breakpoint Locations ──────────────────────────────────────────

    fn engineBreakpointLocations(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, end_line: ?u32) anyerror![]const types.BreakpointLocation {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        var locations = std.ArrayListUnmanaged(types.BreakpointLocation).empty;
        errdefer locations.deinit(allocator);

        const end = end_line orelse line;

        for (self.line_entries) |entry| {
            if (entry.end_sequence) continue;
            if (entry.line >= line and entry.line <= end) {
                // Check if file matches
                if (self.file_entries.len > 0 and entry.file_index < self.file_entries.len) {
                    const entry_file = self.file_entries[entry.file_index].name;
                    if (std.mem.indexOf(u8, entry_file, file) != null or
                        std.mem.indexOf(u8, file, std.fs.path.basename(entry_file)) != null)
                    {
                        // Check for duplicate line numbers
                        var duplicate = false;
                        for (locations.items) |existing| {
                            if (existing.line == entry.line) {
                                duplicate = true;
                                break;
                            }
                        }
                        if (!duplicate) {
                            try locations.append(allocator, .{
                                .line = entry.line,
                            });
                        }
                    }
                }
            }
        }

        return try locations.toOwnedSlice(allocator);
    }

    // ── Restart ────────────────────────────────────────────────────────

    fn engineRestart(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        if (!self.launched) return error.NotLaunched;

        // We need the program path to restart
        const path = self.program_path orelse return error.NotSupported;

        // Save old ASLR slide before restarting
        const old_slide = self.aslr_slide;

        // Kill current process
        self.process.kill() catch {};

        // Re-launch with the saved program path
        const config = LaunchConfig{
            .program = path,
            .args = &.{},
        };
        self.launched = false;
        try engineLaunch(ctx, allocator, config);

        // Adjust existing breakpoint addresses for new ASLR slide and re-arm
        const slide_diff = self.aslr_slide - old_slide;
        if (slide_diff != 0) {
            for (self.bp_manager.breakpoints.items) |*bp| {
                if (bp.enabled) {
                    if (slide_diff > 0) {
                        bp.address +%= @intCast(@as(u64, @intCast(slide_diff)));
                    } else {
                        bp.address -%= @intCast(@as(u64, @intCast(-slide_diff)));
                    }
                }
            }
        }
        self.rearmAllBreakpoints();
        self.stepping_past_bp = null;
        self.stepping_past_wp = null;
        self.hw_watchpoints = [_]HardwareWatchpoint{.{}} ** 4;
    }

    // ── Write Registers ──────────────────────────────────────────────

    fn engineWriteRegisters(ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32, name: []const u8, value: u64) anyerror!void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        _ = allocator;
        _ = thread_id;
        if (!self.launched) return error.NotLaunched;
        if (self.core_dump != null) return error.NotSupported; // core dumps are read-only

        // Read current register state, modify the target register, write back
        var regs = try self.process.readRegisters();

        // Map register name to field
        if (std.mem.eql(u8, name, "pc") or std.mem.eql(u8, name, "rip")) {
            regs.pc = value;
        } else if (std.mem.eql(u8, name, "sp") or std.mem.eql(u8, name, "rsp")) {
            regs.sp = value;
        } else if (std.mem.eql(u8, name, "fp") or std.mem.eql(u8, name, "rbp")) {
            regs.fp = value;
        } else if (std.mem.eql(u8, name, "flags") or std.mem.eql(u8, name, "rflags")) {
            regs.flags = value;
        } else {
            // Try GPR by index: x0-x31 or r0-r15
            const gpr_idx = parseGprIndex(name) orelse return error.InvalidRegister;
            if (gpr_idx >= 32) return error.InvalidRegister;
            regs.gprs[gpr_idx] = value;
        }

        try self.process.writeRegisters(regs);
    }

    fn parseGprIndex(name: []const u8) ?usize {
        if (name.len >= 2 and name[0] == 'x') {
            return std.fmt.parseInt(usize, name[1..], 10) catch null;
        } else if (name.len >= 2 and name[0] == 'r') {
            // x86-64: rax=0, rcx=1, rdx=2, rbx=3, rsi=6, rdi=7, r8-r15
            const suffix = name[1..];
            if (std.mem.eql(u8, suffix, "ax")) return 0;
            if (std.mem.eql(u8, suffix, "cx")) return 1;
            if (std.mem.eql(u8, suffix, "dx")) return 2;
            if (std.mem.eql(u8, suffix, "bx")) return 3;
            if (std.mem.eql(u8, suffix, "si")) return 6;
            if (std.mem.eql(u8, suffix, "di")) return 7;
            // r8-r15
            return std.fmt.parseInt(usize, suffix, 10) catch null;
        }
        return null;
    }

    // ── Variable Location ────────────────────────────────────────────

    fn engineVariableLocation(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, _: u32) anyerror!types.VariableLocationInfo {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));

        // Read current register state
        const regs = self.process.readRegisters() catch {
            return .{
                .name = try allocator.dupe(u8, name),
                .location_type = try allocator.dupe(u8, "unknown"),
            };
        };

        const pc = regs.pc;
        if (pc == 0) return .{
            .name = try allocator.dupe(u8, name),
            .location_type = try allocator.dupe(u8, "unknown"),
        };

        // Resolve debug data (dSYM, main binary, or ELF)
        const dd = self.resolveDebugData() orelse return .{
            .name = try allocator.dupe(u8, name),
            .location_type = try allocator.dupe(u8, "unknown"),
        };

        // Compute un-slid PC for DWARF lookup
        const dwarf_pc: u64 = if (self.aslr_slide >= 0)
            pc -% @as(u64, @intCast(self.aslr_slide))
        else
            pc +% @as(u64, @intCast(-self.aslr_slide));

        // Parse scoped variables at current PC
        const scoped = parser.parseScopedVariables(
            dd.info_data,
            dd.abbrev_data,
            dd.str_data,
            .{
                .debug_str_offsets = dd.str_offsets_data,
                .debug_addr = dd.addr_data,
                .debug_ranges = dd.ranges_data,
                .debug_rnglists = dd.rnglists_data,
                .debug_loc = dd.loc_data,
                .debug_loclists = dd.loclists_data,
            },
            dwarf_pc,
            allocator,
            if (self.abbrev_cache) |*ac| ac else null,
            self.cuHintForPC(dwarf_pc),
            if (self.type_die_cache) |*tdc| tdc else null,
        ) catch return .{
            .name = try allocator.dupe(u8, name),
            .location_type = try allocator.dupe(u8, "unknown"),
        };
        defer parser.freeScopedVariables(scoped, allocator);

        // Build register adapter
        var reg_adapter = RegisterAdapter{ .regs = regs };
        const reg_provider = reg_adapter.provider();

        // Evaluate frame base (pass real CFA for DW_OP_call_frame_cfa)
        const frame_base: ?u64 = if (scoped.frame_base_expr.len > 0) blk: {
            const fb_result = location.evalLocationEx(scoped.frame_base_expr, reg_provider, null, null, .{ .cfa = self.computeCfa(regs) });
            break :blk switch (fb_result) {
                .address => |addr| addr,
                .value => |val| val,
                .register => |reg| reg_provider.read(reg),
                .empty, .implicit_pointer, .composite => null,
            };
        } else null;

        // Find the target variable and evaluate its location
        for (scoped.variables) |v| {
            if (!std.mem.eql(u8, v.name, name)) continue;
            if (v.location_expr.len == 0) {
                return .{
                    .name = try allocator.dupe(u8, name),
                    .location_type = try allocator.dupe(u8, "optimized_out"),
                };
            }

            const loc = location.evalLocation(v.location_expr, reg_provider, frame_base);
            return switch (loc) {
                .address => |addr| .{
                    .name = try allocator.dupe(u8, name),
                    .location_type = try allocator.dupe(u8, "stack"),
                    .address = addr,
                },
                .register => |reg| blk: {
                    var reg_buf: [32]u8 = undefined;
                    const reg_name = std.fmt.bufPrint(&reg_buf, "reg{d}", .{reg}) catch "unknown";
                    break :blk .{
                        .name = try allocator.dupe(u8, name),
                        .location_type = try allocator.dupe(u8, "register"),
                        .register = try allocator.dupe(u8, reg_name),
                    };
                },
                .value => .{
                    .name = try allocator.dupe(u8, name),
                    .location_type = try allocator.dupe(u8, "constant"),
                },
                .composite => .{
                    .name = try allocator.dupe(u8, name),
                    .location_type = try allocator.dupe(u8, "split"),
                },
                .implicit_pointer => .{
                    .name = try allocator.dupe(u8, name),
                    .location_type = try allocator.dupe(u8, "register"),
                },
                .empty => .{
                    .name = try allocator.dupe(u8, name),
                    .location_type = try allocator.dupe(u8, "optimized_out"),
                },
            };
        }

        // Variable not found in current scope
        return .{
            .name = try allocator.dupe(u8, name),
            .location_type = try allocator.dupe(u8, "unknown"),
        };
    }

    // ── Drain Notifications ────────────────────────────────────────

    fn engineDrainNotifications(ctx: *anyopaque, allocator: std.mem.Allocator) []const types.DebugNotification {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        var notifications = std.ArrayListUnmanaged(types.DebugNotification).empty;

        // Read captured stdout
        const maybe_stdout = self.process.readCapturedOutput(allocator) catch null;
        if (maybe_stdout) |stdout_data| {
            defer allocator.free(stdout_data);
            // Build JSON params for output event — skip notification if any JSON op fails
            const params_json: ?[]const u8 = blk: {
                var aw: std.io.Writer.Allocating = .init(allocator);
                var jw: std.json.Stringify = .{ .writer = &aw.writer };
                jw.beginObject() catch {
                    aw.deinit();
                    break :blk null;
                };
                jw.objectField("category") catch {
                    aw.deinit();
                    break :blk null;
                };
                jw.write("stdout") catch {
                    aw.deinit();
                    break :blk null;
                };
                jw.objectField("output") catch {
                    aw.deinit();
                    break :blk null;
                };
                jw.write(stdout_data) catch {
                    aw.deinit();
                    break :blk null;
                };
                jw.endObject() catch {
                    aw.deinit();
                    break :blk null;
                };
                break :blk aw.toOwnedSlice() catch {
                    aw.deinit();
                    break :blk null;
                };
            };
            if (params_json) |pj| {
                const method = allocator.dupe(u8, "output") catch {
                    allocator.free(pj);
                    return notifications.toOwnedSlice(allocator) catch &.{};
                };
                notifications.append(allocator, .{
                    .method = method,
                    .params_json = pj,
                }) catch {
                    allocator.free(method);
                    allocator.free(pj);
                };
            }
        }

        return notifications.toOwnedSlice(allocator) catch &.{};
    }

    fn engineDeinit(ctx: *anyopaque) void {
        const self: *DwarfEngine = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "DwarfEngine initial state" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expect(!engine.launched);
    try std.testing.expect(engine.program_path == null);
    try std.testing.expectEqual(@as(usize, 0), engine.bp_manager.list().len);
}

test "DwarfEngine implements ActiveDriver interface" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    const driver = engine.activeDriver();
    try std.testing.expectEqual(ActiveDriver.DriverType.native, driver.driver_type);
}

test "DwarfEngine launches fixture binary" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;

    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.process.spawn(std.testing.allocator, "/bin/echo", &.{"test"}) catch return error.SkipZigTest;
    engine.launched = true;
    engine.program_path = std.testing.allocator.dupe(u8, "/bin/echo") catch return error.SkipZigTest;

    try std.testing.expect(engine.launched);
    try std.testing.expect(engine.process.pid != null);
}

test "DwarfEngine stop terminates process cleanly" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;

    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.process.spawn(std.testing.allocator, "/usr/bin/sleep", &.{"10"}) catch return error.SkipZigTest;
    engine.launched = true;
    engine.program_path = std.testing.allocator.dupe(u8, "/usr/bin/sleep") catch return error.SkipZigTest;

    try std.testing.expect(engine.process.pid != null);

    var driver = engine.activeDriver();
    driver.stop(std.testing.allocator) catch {};
    try std.testing.expect(!engine.launched);
    try std.testing.expect(engine.process.pid == null);
}

test "DwarfEngine setBreakpoint without debug info returns unverified" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    // No binary loaded, no line entries — use the vtable via activeDriver
    var driver = engine.activeDriver();
    const bp = try driver.setBreakpoint(std.testing.allocator, "test.c", 10, null);
    try std.testing.expect(!bp.verified);
}

test "DwarfEngine stores inlined subroutine info" {
    var engine = DwarfEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Initially no inlined subroutines
    try std.testing.expectEqual(@as(usize, 0), engine.inlined_subs.len);

    // Set up inlined subroutine data directly (simulating what loadFunctionInfo would do)
    const subs = try std.testing.allocator.alloc(parser.InlinedSubroutineInfo, 2);
    subs[0] = .{
        .abstract_origin = 100,
        .call_file = 1,
        .call_line = 10,
        .call_column = 3,
        .low_pc = 0x2000,
        .high_pc = 0x2080,
        .name = "inlined_add",
    };
    subs[1] = .{
        .abstract_origin = 200,
        .call_file = 1,
        .call_line = 20,
        .call_column = 1,
        .low_pc = 0x3000,
        .high_pc = 0x3040,
        .name = "inlined_mul",
    };
    engine.inlined_subs = subs;

    try std.testing.expectEqual(@as(usize, 2), engine.inlined_subs.len);
    try std.testing.expectEqualStrings("inlined_add", engine.inlined_subs[0].name.?);
    try std.testing.expectEqualStrings("inlined_mul", engine.inlined_subs[1].name.?);
}

test "getFileName resolves file entries by 0-based index" {
    const files = [_]parser.FileEntry{
        .{ .name = "main.c", .dir_index = 0 },
        .{ .name = "utils.h", .dir_index = 0 },
    };

    // 0-based indices (normalized by parser)
    try std.testing.expectEqualStrings("main.c", DwarfEngine.getFileName(&files, 0));
    try std.testing.expectEqualStrings("utils.h", DwarfEngine.getFileName(&files, 1));

    // Out of range
    try std.testing.expectEqualStrings("<unknown>", DwarfEngine.getFileName(&files, 10));
}
