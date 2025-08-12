# Vim/Neovim Markdown Command Executor Product Requirements Document (PRD)

## Goals and Background Context

### Goals
• Enable seamless execution of shell commands directly from markdown code blocks within Vim/Neovim
• Provide non-intrusive visual feedback and result tracking without modifying original markdown files
• Support sequential execution workflows with error-gating for reliable automation
• Create an extensible foundation for future multi-language execution support
• Deliver three distinct execution modes (manual, next-block, execute-all) for different workflow needs

### Background Context
Developers and technical writers frequently work with markdown files containing shell commands for documentation, tutorials, and automation workflows. Currently, there's no seamless way to execute these commands directly from within Vim/Neovim, forcing users to manually copy-paste commands to terminal windows, which breaks focus and interrupts the editing workflow.

This plugin addresses the gap between markdown documentation and command execution by providing a native Neovim solution that preserves environment state, tracks execution results, and maintains the integrity of original markdown files through a separate results tracking system.

### Change Log
| Date | Version | Description | Author |
|------|---------|-------------|---------|
| 2025-08-03 | 1.0 | Initial PRD draft from brainstorm session | John (PM) |
| 2025-08-08 | 1.1 | Updated results sidecar naming/schema, commands list, indicators rehydration, and quickfix/popup behaviors based on implementation | dev.mdc |

## Requirements

### Functional Requirements

- **FR1:** The plugin shall execute shell commands from markdown code blocks using cursor-based selection within Neovim
- **FR2:** The plugin shall provide three execution modes: manual block selection, execute next unexecuted block, and execute all blocks sequentially
- **FR3:** The plugin shall persist environment state and directory changes between command executions within a session
- **FR4:** The plugin shall store execution results in a separate JSON-formatted .result.json file without modifying the original markdown
- **FR5:** The plugin shall provide visual markers using virtual text to indicate execution status of code blocks (executing, executed with success/error)
- **FR6:** The plugin shall execute commands asynchronously with a configurable timeout (default 30 seconds)
- **FR7:** The plugin shall stop sequential execution on command failure (error-gating behavior)
- **FR8:** The plugin shall resolve relative paths relative to the markdown file's directory
- **FR9:** The plugin shall save large outputs (>100 lines) to separate files with references in the main results
- **FR10:** The plugin shall detect binary data in the results and store it in separate files
- **FR11:** The plugin shall provide global shortcuts for all plugin commands
- **FR12:** The plugin shall integrate with quickfix for error navigation
- **FR13:** The plugin allows to jump from markdown file to the results file location where the result of the selected command is
- **FR14:** The plugin allows to keep environment variables between executions
- **FR15:** The plugin allows to display the value of an environment variable of the execution environment for the word under cursor

### Non-Functional Requirements

- **NFR1:** Command execution timeout shall not exceed 30 seconds by default to prevent hanging
- **NFR2:** The plugin shall not expect or handle user input during command execution
- **NFR3:** Multiple Neovim instances shall be able to share the same results file safely
- **NFR4:** Modified code blocks shall lose association with previous execution results
- **NFR5:** The plugin shall provide no undo functionality for command executions
- **NFR6:** The plugin shall implement no command blacklisting or safety guardrails
- **NFR7:** Large result files shall be automatically managed without user intervention
- **NFR8:** The plugin shall follow Neovim configuration best practices for LazyVim integration

## User Interface Design Goals

### Overall UX Vision
The plugin should provide a seamless, non-intrusive experience that feels native to Vim workflows. Users should be able to execute commands with minimal keystrokes while receiving clear visual feedback about execution status and results.

### Key Interaction Paradigms
- **Cursor-based selection:** Natural vim interaction model for selecting code blocks
- **Visual state indicators:** Non-intrusive virtual text markers showing execution status
- **Popup feedback:** Immediate result display without disrupting editing flow
- **Global shortcuts:** Consistent keybindings accessible from any buffer
  
### Commands Overview
- `:MarkdownRun` — Execute current block (default keymap `<leader>rm`)
- `:MarkdownRunNext[!]` — Execute next unexecuted block; with `!`, force re-execute
- `:MarkdownRunAll[!]` — Execute all blocks sequentially; with `!`, continue on errors
- `:MarkdownRunEnv` — Show current session CWD and env summary; value under cursor when applicable
- `:MarkdownRunReset` — Reset session (CWD and environment) for current buffer
- `:MarkdownRunToggleIndicators` — Toggle visual indicators on/off
- `:MarkdownRunQuickfix` — Open quickfix populated with recent execution errors
- `:MarkdownRunOpenResult` — Show the last recorded result for the current block in a popup

### Core Screens and Views
- **Markdown Editor View:** Primary interface with visual execution markers
- **Result Popup:** Overlay display for command output and status
- **Quickfix Window:** Error navigation and debugging interface

### Accessibility: None
*Simple terminal-based interface within Neovim - standard terminal accessibility applies*

### Branding
No specific branding requirements - should follow standard Neovim plugin conventions and integrate seamlessly with user's existing color scheme and configuration.

### Target Device and Platforms: Desktop Only
*Neovim plugin for desktop development environments*

## Technical Assumptions

### Repository Structure: Monorepo
*Single repository for the Neovim plugin with standard plugin structure*

### Service Architecture
**CRITICAL DECISION** - Neovim plugin architecture with the following components:
- **Core execution engine:** Async command processing with environment persistence
- **Result tracking system:** JSON-based storage and retrieval
- **Visual feedback system:** Virtual text integration and popup management
- **Command interface:** Global shortcuts and mode management

### Testing Requirements
**CRITICAL DECISION** - Unit and integration testing approach:
- Unit tests for core execution logic and result parsing
- Integration tests for Neovim API interactions
- Manual testing convenience for different markdown structures
- No automated E2E testing due to editor integration complexity

### Additional Technical Assumptions and Requests
- **Language:** Lua for Neovim plugin development (standard for modern Neovim plugins)
- **Dependencies:** Minimal external dependencies, leverage Neovim's built-in capabilities
- **Configuration:** LazyVim integration priority with sensible defaults
- **File Format:** Pretty-printed JSON results sidecar (`<markdown>.result.json`). The `executions` field is an object map keyed by `sha256(command)`, storing the most recent result per command; the system maintains only the latest association per block. Legacy `.result` files (array format) remain readable.
- **Execution Model:** Async job execution using Neovim's job control API
- **Error Handling:** Quickfix integration for error navigation
- **Compatibility:** Neovim-only (no Vim compatibility) to leverage advanced features

## Epic List

### Epic 1: Foundation & Core Infrastructure
Establish plugin structure, basic command execution, and result tracking system to deliver a minimal viable execution capability.

### Epic 2: Execution Modes & Workflow
Implement the three execution modes (manual, next-block, execute-all) with environment persistence and error-gating for complete workflow functionality.

### Epic 3: Visual Feedback & User Experience
Add virtual text indicators, popup result display, and enhanced user interaction features for a polished editing experience.

## Epic 1: Foundation & Core Infrastructure

**Epic Goal:** Establish plugin structure, basic command execution, and result tracking system to deliver a minimal viable execution capability that allows users to execute shell commands from markdown code blocks and see basic results.

### Story 1.1: Plugin Foundation Setup

**As a** developer,
**I want** a properly structured Neovim plugin with standard configuration,
**so that** I can install and load the plugin in my Neovim environment.

#### Acceptance Criteria
1. Plugin follows standard Neovim plugin directory structure (lua/, plugin/, doc/)
2. Plugin can be installed via popular package managers (LazyVim, Packer, etc.)
3. Plugin loads without errors in Neovim
4. Basic plugin commands are registered and accessible
5. Plugin configuration follows Neovim best practices
6. README with installation instructions is provided

### Story 1.2: Markdown Code Block Detection

**As a** user,
**I want** the plugin to identify shell code blocks in markdown files,
**so that** I can target specific blocks for execution.

#### Acceptance Criteria
1. Plugin correctly identifies fenced code blocks with ```bash, ```sh, or ``` (no language specified)
2. Plugin can determine the current code block based on cursor position
3. Plugin ignores non-shell code blocks (```python, ```javascript, etc.)
4. Plugin handles nested code blocks within list items or blockquotes
5. Plugin provides feedback when cursor is not in a valid code block

### Story 1.3: Basic Shell Command Execution

**As a** user,
**I want** to execute a shell command from a markdown code block,
**so that** I can run commands without leaving my editor.

#### Acceptance Criteria
1. Plugin executes shell commands asynchronously without blocking the editor
2. Commands run in the directory of the markdown file
3. Command execution respects a 30-second timeout
4. Plugin captures both stdout and stderr from command execution
5. Plugin provides immediate feedback when command starts and completes
6. Plugin handles command failures gracefully

### Story 1.4: Results File System Foundation

**As a** user,
**I want** execution results stored in a separate file,
**so that** my original markdown remains unchanged while I can review execution history.

#### Acceptance Criteria
1. Plugin creates a .result file alongside the markdown file (e.g., README.md → README.md.result)
2. Results file uses JSON format for structured data storage
3. Each execution result includes: timestamp, command, exit code, stdout, stderr, duration
4. Plugin handles concurrent access to results file safely
5. Results file is human-readable when opened directly
6. Plugin creates results file directory if it doesn't exist

## Epic 2: Execution Modes & Workflow

**Epic Goal:** Implement the three execution modes (manual, next-block, execute-all) with environment persistence and error-gating to deliver complete workflow functionality that supports both individual command execution and automated sequential processing.

### Story 2.1: Manual Block Execution Mode

**As a** user,
**I want** to execute the current code block under my cursor,
**so that** I can run specific commands on demand.

#### Acceptance Criteria
1. Plugin provides a command/keybinding to execute the current code block
2. Execution only occurs when cursor is within a valid shell code block
3. Plugin displays execution status and results immediately
4. Multiple executions of the same block update the results
5. Plugin maintains execution history for each block
6. User receives clear feedback if no executable block is found at cursor

### Story 2.2: Environment Persistence System

**As a** user,
**I want** environment variables and directory changes to persist between command executions,
**so that** I can build complex workflows that depend on previous commands.

#### Acceptance Criteria
1. Environment variables set in one command are available in subsequent commands
2. Directory changes (cd commands) persist for future executions
3. PATH modifications and exports are maintained across executions
4. Plugin tracks the current working directory and displays it
5. Environment state resets only when explicitly requested or session ends
6. Plugin handles environment corruption gracefully

### Story 2.3: Execute Next Block Mode

**As a** user,
**I want** to execute the next unexecuted code block in the file,
**so that** I can step through commands sequentially without manual cursor movement.

#### Acceptance Criteria
1. Plugin identifies the next unexecuted code block from current cursor position
2. Plugin moves cursor to the next block and executes it
3. Plugin provides visual indication of which block will be executed next
4. Plugin handles end-of-file gracefully when no more blocks exist
5. Plugin skips already-executed blocks unless forced to re-execute
6. User can restart from the beginning or continue from current position

### Story 2.4: Execute All Blocks Mode

**As a** user,
**I want** to execute all code blocks in the file sequentially,
**so that** I can run complete automation workflows with one command.

#### Acceptance Criteria
1. Plugin executes all shell code blocks in document order
2. Execution stops immediately if any command fails (non-zero exit code)
3. Plugin provides progress feedback during batch execution
4. User can cancel batch execution while in progress
5. Plugin summarizes results of batch execution (success/failure counts)
6. Failed executions provide clear error location and details

### Story 2.5: Visual Execution Status Indicators

**As a** user,
**I want** to see visual indicators of which blocks have been executed,
**so that** I can track my progress through the document.

#### Acceptance Criteria
1. Plugin uses virtual text to mark executed blocks with status indicators
2. Different visual styles for: not executed, executing, success, failed
3. Indicators are non-intrusive and don't interfere with editing
4. Visual markers update in real-time during execution
5. Markers persist across editor sessions when results file exists
6. User can toggle visual indicators on/off

## Epic 3: Visual Feedback & User Experience

**Epic Goal:** Add enhanced visual feedback, popup result display, and polished user interaction features to deliver a seamless editing experience that provides comprehensive information without disrupting the development workflow.

### Story 3.1: Popup Result Display

**As a** user,
**I want** to see command results in a popup window,
**so that** I can review output without leaving my current editing context.

#### Acceptance Criteria
1. Plugin displays command results in a floating popup window
2. Popup shows stdout, stderr, exit code, and execution duration
3. Popup can be dismissed with Escape key or by moving cursor
4. Large outputs are truncated with option to view full results
5. Popup positioning avoids obscuring current cursor location
6. Popup styling integrates with user's colorscheme

### Story 3.2: Large Output Management

**As a** user,
**I want** large command outputs stored in separate files,
**so that** my results file stays manageable while preserving all output data.

#### Acceptance Criteria
1. Outputs exceeding 100 lines are automatically saved to separate files
2. Results file contains reference to large output file location
3. Large output files use descriptive naming (timestamp + block identifier)
4. Plugin provides easy navigation to large output files
5. Binary data is detected and saved appropriately
6. Large output files are cleaned up based on configurable retention policy

### Story 3.3: Enhanced Error Handling and Quickfix Integration

**As a** user,
**I want** errors integrated with Neovim's quickfix system,
**so that** I can navigate and debug command failures efficiently.

#### Acceptance Criteria
1. Command errors populate Neovim's quickfix list
2. Quickfix entries include file location, command, and error details
3. User can navigate between errors using standard quickfix commands
4. Plugin provides command to open quickfix window with recent errors
5. Error messages are parsed for common patterns (file:line format)
6. Timeout errors are clearly distinguished from command failures

### Story 3.4: Global Shortcuts and Command Interface

**As a** user,
**I want** convenient keyboard shortcuts for all plugin functions,
**so that** I can use the plugin efficiently without disrupting my editing flow.

#### Acceptance Criteria
1. Plugin provides default keybindings for all major functions
2. Keybindings are configurable by users
3. Plugin commands are accessible via Neovim's command interface
4. Tab completion works for plugin commands
5. Plugin provides help command showing all available shortcuts
6. Shortcuts work consistently across different buffer types

### Story 3.5: Configuration and Customization

**As a** user,
**I want** to customize plugin behavior and appearance,
**so that** the plugin integrates seamlessly with my development environment.

#### Acceptance Criteria
1. Timeout duration is configurable
2. Visual indicator styles can be customized
3. Result file location and naming can be configured
4. Plugin can be disabled for specific file types or directories
5. LazyVim integration provides sensible defaults
6. Configuration changes take effect immediately without restart

## Checklist Results Report

*Running PM checklist validation...*

### PRD Validation Summary

**Overall PRD Completeness:** 85%
**MVP Scope Assessment:** Just Right - Focused on core value delivery
**Readiness for Architecture Phase:** Ready
**Most Critical Gaps:** Missing explicit success metrics and user research validation

### Category Analysis

| Category                         | Status | Critical Issues |
| -------------------------------- | ------ | --------------- |
| 1. Problem Definition & Context  | PASS   | Success metrics could be more specific |
| 2. MVP Scope Definition          | PASS   | Well-bounded scope with clear rationale |
| 3. User Experience Requirements  | PASS   | Clear interaction patterns defined |
| 4. Functional Requirements       | PASS   | Comprehensive and testable |
| 5. Non-Functional Requirements   | PASS   | Appropriate constraints defined |
| 6. Epic & Story Structure        | PASS   | Logical sequencing and dependencies |
| 7. Technical Guidance            | PASS   | Clear technology choices and constraints |
| 8. Cross-Functional Requirements | PARTIAL| Limited data/integration requirements |
| 9. Clarity & Communication       | PASS   | Well-structured and comprehensive |

### Top Issues by Priority

**MEDIUM:**
- Success metrics could be more measurable (user adoption, usage frequency)
- No explicit user research validation (based on brainstorm but not validated)
- Limited operational requirements for plugin distribution

**LOW:**
- Could benefit from more detailed error scenarios
- Integration testing approach could be more specific

### MVP Scope Assessment
**Appropriately Sized:** The three-epic structure delivers incremental value while maintaining focus on core shell execution capability. Each epic builds logically on the previous one.

**Strengths:**
- Clear progression from foundation to full functionality
- Well-defined boundaries (shell-only, no safety guardrails)
- Reasonable story sizing for development

### Technical Readiness
**Architecture Ready:** Clear technical constraints and technology choices provided. Neovim-only decision enables advanced features. JSON storage format supports extensibility.

**Key Guidance for Architect:**
- Async execution model is critical for user experience
- Environment persistence requires careful state management
- Virtual text integration for visual feedback
- Plugin follows standard Neovim patterns

### Recommendations
1. **Consider adding** basic success metrics (e.g., daily active users, commands executed per session)
2. **Validate assumptions** with target users once MVP is available
3. **Document** plugin distribution and installation strategy
4. **Ready for architect** - requirements are comprehensive and technically sound

## Next Steps

### UX Expert Prompt
Review the PRD and create detailed interaction flows for the three execution modes, focusing on visual feedback patterns and error state handling within the Neovim environment.

### Architect Prompt
Design the technical architecture for a Neovim plugin that executes shell commands from markdown code blocks, implementing async execution, environment persistence, and JSON-based result tracking as specified in this PRD.
