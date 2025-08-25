#!/bin/bash

# =====================================================================================
# == Final Adaptive Build Script v11.0 (Two-Phase Build) ==
# =====================================================================================
#
# This version implements a two-phase build to handle memory-intensive targets
# proactively, preventing the inefficient restart cycle.
#
# 1. Phase 1: Build the known heavy target ('flash-attention') in a conservative mode.
# 2. Phase 2: Run the full adaptive build for all remaining targets.
#
# This eliminates the need to detect 'flash-attention' mid-build, making the
# process faster and more reliable.

# --- Configuration ---
CMAKE_SETUP_COMMAND="python setup.py bdist_wheel --cmake-only"
PACKAGE_COMMAND_ARRAY=(python setup.py bdist_wheel)
BUILD_DIR="./build"

# --- Target-Specific Configuration ---
# The exact name of the memory-intensive ninja target.
# Find this with `ninja -C build -t targets`.
FLASH_ATTENTION_TARGET_NAME="flash_attention"
# The safe number of jobs to use for building ONLY this target.
FLASH_ATTENTION_CONSERVATIVE_JOBS=8

# --- Governor Config ---
CHECK_INTERVAL_FAST_SEC=15
CHECK_INTERVAL_THROTTLE_SEC=30

MEMORY_DOWNSHIFT_THRESHOLD_GB=50

DEFAULT_JOBS_LEVELS=(32 16 8 4 2)
# NOTE: Flash Attention job levels are no longer needed here, as it's built separately.
JOBS_LEVELS=("${DEFAULT_JOBS_LEVELS[@]}")

THROTTLE_TASK_COUNT=5
CLEANUP_WINDOW_SEC=15
CLEANUP_PATTERNS=(-name "*.o" -o -name "*.os" -o -name "*.d")
TERMINATION_WAIT_TIMEOUT_SEC=10

# --- Cooldown Configuration ---
FORCED_COOLDOWN_DURATION_SEC=30

# --- Pre-flight Check (Condensed for brevity) ---
echo "--- Build Pre-flight Check ---"
if ! command -v bc &> /dev/null; then echo "Error: 'bc' not installed." >&2; exit 1; fi
if [ ! -f "${BUILD_DIR}/build.ninja" ]; then
    echo "Ninja build file not found. Attempting to configure..."
    if [ ! -f "setup.py" ]; then echo "FATAL: 'setup.py' not found." >&2; exit 1; fi
    if ! eval "$CMAKE_SETUP_COMMAND"; then echo "CMAKE SETUP FAILED." >&2; exit 1; fi
    if [ ! -f "${BUILD_DIR}/build.ninja" ]; then echo "Build file still missing after setup." >&2; exit 1; fi
    echo "Project configured successfully."
else echo "Build directory is already configured. Skipping setup."; fi
echo "--- Pre-flight Check Complete ---"

# --- State & Conversions ---
CPU_STALL_THRESHOLD_PERCENT=2.5; CPU_STALL_DURATION_SEC=10
MEMORY_DOWNSHIFT_THRESHOLD_KB=$((MEMORY_DOWNSHIFT_THRESHOLD_GB * 1024 * 1024))
cd "${BUILD_DIR}" || exit
CURRENT_LEVEL_INDEX=0; MAX_LEVEL_INDEX=$((${#JOBS_LEVELS[@]} - 1))
CPU_STALL_START_TIME=0; LAST_CPU_IDLE=0; LAST_CPU_TOTAL=0
KILL_REASON=""

# --- Helper Functions (identical to previous version) ---
function get_cpu_utilization() {
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    local current_idle=$((idle + iowait)); local current_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    if [ "$LAST_CPU_TOTAL" -eq 0 ]; then LAST_CPU_IDLE=$current_idle; LAST_CPU_TOTAL=$current_total; echo "-1.0"; return; fi
    local delta_idle=$((current_idle - LAST_CPU_IDLE)); local delta_total=$((current_total - LAST_CPU_TOTAL))
    if [ "$delta_total" -eq 0 ]; then echo "-1.0"; return; fi
    local delta_busy=$((delta_total - delta_idle)); echo "scale=2; 100 * $delta_busy / $delta_total" | bc
    LAST_CPU_IDLE=$current_idle; LAST_CPU_TOTAL=$current_total
}
function terminate_and_wait_for_pg() {
    local pgid=$1; if ! pgrep -g "$pgid" > /dev/null; then return; fi
    echo -e "\n\033[36m>> Terminating process group ${pgid}...\033[0m"
    local signals=( "-2" "-15" "-9" ); local signal_names=( "SIGINT" "SIGTERM" "SIGKILL" )
    for i in "${!signals[@]}"; do
        echo "   - Sending ${signal_names[$i]} to all processes in group."
        kill -- "${signals[$i]}" -"$pgid" 2>/dev/null
        local end_time=$(( $(date +%s) + TERMINATION_WAIT_TIMEOUT_SEC ))
        while [ "$(date +%s)" -lt "$end_time" ]; do
            if ! pgrep -g "$pgid" > /dev/null; then echo -e "   \033[32m- Process group terminated cleanly.\033[0m"; return 0; fi
            sleep 0.5
        done
    done; echo -e "   \033[33;1m- Warning: Process group ${pgid} did not terminate cleanly after all signals.\033[0m"
}
function clean_recent_outputs() {
    echo -e "\033[36m>> Cleaning potential artifacts from the last ${CLEANUP_WINDOW_SEC}s to prevent corruption...\033[0m"
    local threshold_timestamp; threshold_timestamp=$(date -d "-${CLEANUP_WINDOW_SEC} seconds" "+%Y-%m-%d %H:%M:%S")
    local files_to_clean; files_to_clean=$(find . -type f \( "${CLEANUP_PATTERNS[@]}" \) -newermt "$threshold_timestamp" -print)
    if [ -n "$files_to_clean" ]; then
        echo "   - Found and removing the following suspect files:"; echo "$files_to_clean" | sed 's/^/     /' | xargs -r rm -f
    else echo "   - No recently modified artifacts found to clean."; fi
}
function garbage_collect_zombies() {
    local zombie_count
    zombie_count=$(ps -o ppid=,stat= | awk -v parent_pid=$$ '$1==parent_pid && $2=="Z"' | wc -l)
    if [ "$zombie_count" -gt 0 ]; then
        echo -e "\033[36m>> Garbage Collector: Found ${zombie_count} zombie process(es). Reaping...\033[0m"
        while ps -o ppid=,stat= | awk -v parent_pid=$$ '$1==parent_pid && $2=="Z"' | grep -q .; do
            wait -n 2>/dev/null || break
        done
        echo -e "   \033[32m- Garbage collection complete.\033[0m"
    fi
}

# =================================================================================
# == PHASE 1: Build Flash-Attention with an Active Governor ==
# =================================================================================
# This phase now uses its own adaptive governor to build the memory-intensive
# target. It starts at 8 jobs and can gear down to 4 or 2 if needed.
echo -e "\n========================================================"
echo -e ">> PHASE 1: Starting Adaptive Build for '${FLASH_ATTENTION_TARGET_NAME}'"
echo "========================================================"
echo "Job Levels: 8, 4, 2 | Memory Threshold: ${MEMORY_DOWNSHIFT_THRESHOLD_GB}GB | Cooldown: ${FORCED_COOLDOWN_DURATION_SEC}s"

# --- Phase 1 Specific State ---
PHASE1_JOBS_LEVELS=(8 4 2)
CURRENT_LEVEL_INDEX=0

while true; do
    MAX_LEVEL_INDEX=$((${#PHASE1_JOBS_LEVELS[@]} - 1))
    CURRENT_JOBS=${PHASE1_JOBS_LEVELS[$CURRENT_LEVEL_INDEX]}

    echo -e "\n--------------------------------------------------------"
    if [ $CURRENT_LEVEL_INDEX -eq 0 ]; then
        echo ">> Phase 1: Attempting build with -j$CURRENT_JOBS"
        CHECK_INTERVAL=$CHECK_INTERVAL_FAST_SEC
    else
        echo ">> Phase 1 (Throttled): Resuming in gear $((CURRENT_LEVEL_INDEX + 1))/${#PHASE1_JOBS_LEVELS[@]} with -j$CURRENT_JOBS"
        CHECK_INTERVAL=$CHECK_INTERVAL_THROTTLE_SEC
    fi
    echo "--------------------------------------------------------"

    PIPE_NAME="/tmp/ninja_pipe_$$"; mkfifo "$PIPE_NAME"
    # CRITICAL CHANGE: The ninja command now specifically builds the flash-attention target
    setsid stdbuf -oL ninja -j"$CURRENT_JOBS" ${FLASH_ATTENTION_TARGET_NAME} > "$PIPE_NAME" 2>&1 &
    NINJA_PID=$!

    INTENTIONALLY_KILLED=false; TASKS_COMPLETED_IN_SESSION=0; exec 3< "$PIPE_NAME"

    while ps -p $NINJA_PID > /dev/null; do
        if read -r -t "$CHECK_INTERVAL" -u 3 NINJA_LINE; then
            echo "$NINJA_LINE"
            if [[ $NINJA_LINE =~ \[([0-9]+)/[0-9]+\] ]]; then TASKS_COMPLETED_IN_SESSION=$((TASKS_COMPLETED_IN_SESSION + 1)); fi
        fi

        MEM_INFO=$(cat /proc/meminfo); MEM_TOTAL_KB=$(echo "$MEM_INFO" | grep MemTotal | awk '{print $2}'); MEM_AVAIL_KB=$(echo "$MEM_INFO" | grep MemAvailable | awk '{print $2}'); MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))

        # Reactive Memory Downshift (using Phase 1 job levels)
        if [ "$MEM_USED_KB" -gt "$MEMORY_DOWNSHIFT_THRESHOLD_KB" ]; then
            if [ "$CURRENT_LEVEL_INDEX" -lt "$MAX_LEVEL_INDEX" ]; then
                echo -e "\n\033[33;1m!! PHASE 1 MEMORY THRESHOLD CROSSED !! Downshifting...\033[0m"
                KILL_REASON="MEMORY_DOWNSHIFT"; terminate_and_wait_for_pg "$NINJA_PID"; INTENTIONALLY_KILLED=true; CURRENT_LEVEL_INDEX=$((CURRENT_LEVEL_INDEX + 1)); break
            fi
        fi

        # Incremental Predictive Upshift (using Phase 1 job levels)
        if [ "$CURRENT_LEVEL_INDEX" -gt 0 ] && [ "$TASKS_COMPLETED_IN_SESSION" -ge "$THROTTLE_TASK_COUNT" ]; then
            next_level_index=$(( CURRENT_LEVEL_INDEX - 1 )); next_level_jobs=${PHASE1_JOBS_LEVELS[$next_level_index]}
            predicted_mem_kb=$(( MEM_USED_KB * next_level_jobs / CURRENT_JOBS ))
            if [ "$predicted_mem_kb" -lt "$MEMORY_DOWNSHIFT_THRESHOLD_KB" ]; then
                echo -e "\n\033[32;1m>> Phase 1: Throttle batch complete. Attempting to upshift to j${next_level_jobs}...\033[0m"
                KILL_REASON="UPSHIFT"; terminate_and_wait_for_pg "$NINJA_PID"; INTENTIONALLY_KILLED=true; CURRENT_LEVEL_INDEX=$next_level_index; break
            else
                predicted_mem_gb=$(( predicted_mem_kb / 1024 / 1024 ))
                echo -e "\n\033[33;1m!! PHASE 1 PREDICTIVE GOVERNOR: Upshift to j${next_level_jobs} aborted (Predicted: ${predicted_mem_gb}GB).\033[0m"
                TASKS_COMPLETED_IN_SESSION=0
            fi
        fi

        # CPU Stall Governor
        UTILIZATION=$(get_cpu_utilization); if [ "$UTILIZATION" != "-1.0" ] && [ "$(echo "$UTILIZATION < $CPU_STALL_THRESHOLD_PERCENT" | bc)" -eq 1 ]; then
            if [ "$CPU_STALL_START_TIME" -eq 0 ]; then CPU_STALL_START_TIME=$(date +%s); else
                if [ "$(( $(date +%s) - CPU_STALL_START_TIME ))" -ge "$CPU_STALL_DURATION_SEC" ]; then
                    echo -e "\n\033[33;1m!! PHASE 1 CPU STALLED... Restarting ninja.\033[0m"; KILL_REASON="CPU_STALL"; terminate_and_wait_for_pg "$NINJA_PID"; INTENTIONALLY_KILLED=true; CPU_STALL_START_TIME=0; break
                fi
            fi
        else CPU_STALL_START_TIME=0; fi
    done

    wait $NINJA_PID 2>/dev/null; NINJA_EXIT_CODE=$?; exec 3<&-; rm -f "$PIPE_NAME"

    if [ "$INTENTIONALLY_KILLED" = true ]; then
        clean_recent_outputs
        garbage_collect_zombies
        if [[ "$KILL_REASON" == MEMORY* ]]; then
            echo -e "\033[36m>> Phase 1: High memory event. Forcing ${FORCED_COOLDOWN_DURATION_SEC}s cooldown...\033[0m"; sleep "$FORCED_COOLDOWN_DURATION_SEC"; echo -e "   \033[32m- Cooldown complete.\033[0m"
        fi
        KILL_REASON=""; continue
    fi

    # Finalization for Phase 1
    if [ $NINJA_EXIT_CODE -eq 0 ]; then
        echo -e "\n\033[32;1m>> PHASE 1 SUCCEEDED. '${FLASH_ATTENTION_TARGET_NAME}' is built.\033[0m"
        break # Exit the Phase 1 loop and proceed to Phase 2
    else
        echo -e "\n*** PHASE 1 FAILED with a critical error (exit code $NINJA_EXIT_CODE). ***" >&2
        exit 1
    fi
done


# --- PHASE 2: Main Adaptive Build Loop ---
echo -e "\n========================================================"
echo ">> PHASE 2: Starting Adaptive Build for all remaining targets..."
echo "========================================================"
echo "Max Jobs: ${JOBS_LEVELS[0]} | Memory Threshold: ${MEMORY_DOWNSHIFT_THRESHOLD_GB}GB | Cooldown: ${FORCED_COOLDOWN_DURATION_SEC}s"

while true; do
    MAX_LEVEL_INDEX=$((${#JOBS_LEVELS[@]} - 1)); CURRENT_JOBS=${JOBS_LEVELS[$CURRENT_LEVEL_INDEX]}
    echo -e "\n========================================================"
    if [ $CURRENT_LEVEL_INDEX -eq 0 ]; then echo ">> Full Speed: Resuming with -j$CURRENT_JOBS"; CHECK_INTERVAL=$CHECK_INTERVAL_FAST_SEC; else echo ">> Throttling: Resuming in gear $((CURRENT_LEVEL_INDEX + 1))/${#JOBS_LEVELS[@]} with -j$CURRENT_JOBS"; CHECK_INTERVAL=$CHECK_INTERVAL_THROTTLE_SEC; fi
    echo "========================================================"
    
    PIPE_NAME="/tmp/ninja_pipe_$$"; mkfifo "$PIPE_NAME"
    setsid stdbuf -oL ninja -j"$CURRENT_JOBS" > "$PIPE_NAME" 2>&1 &
    NINJA_PID=$!
    
    INTENTIONALLY_KILLED=false; TASKS_COMPLETED_IN_SESSION=0; exec 3< "$PIPE_NAME"
    
    while ps -p $NINJA_PID > /dev/null; do
        if read -r -t "$CHECK_INTERVAL" -u 3 NINJA_LINE; then
            echo "$NINJA_LINE"
            if [[ $NINJA_LINE =~ \[([0-9]+)/[0-9]+\] ]]; then TASKS_COMPLETED_IN_SESSION=$((TASKS_COMPLETED_IN_SESSION + 1)); fi
            
            # ===============================================================================
            # == NOTE: The reactive Flash-Attention detection logic has been REMOVED. ==
            # == It is no longer needed due to the proactive two-phase build approach.   ==
            # ===============================================================================

        fi

        MEM_INFO=$(cat /proc/meminfo); MEM_TOTAL_KB=$(echo "$MEM_INFO" | grep MemTotal | awk '{print $2}'); MEM_AVAIL_KB=$(echo "$MEM_INFO" | grep MemAvailable | awk '{print $2}'); MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))

        # Reactive Memory Downshift
        if [ "$MEM_USED_KB" -gt "$MEMORY_DOWNSHIFT_THRESHOLD_KB" ]; then
            if [ "$CURRENT_LEVEL_INDEX" -lt "$MAX_LEVEL_INDEX" ]; then
                echo -e "\n\033[33;1m!! MEMORY THRESHOLD CROSSED !! Downshifting one level...\033[0m"
                KILL_REASON="MEMORY_DOWNSHIFT"; terminate_and_wait_for_pg "$NINJA_PID"; INTENTIONALLY_KILLED=true; CURRENT_LEVEL_INDEX=$((CURRENT_LEVEL_INDEX + 1)); break
            fi
        fi
        
        # Incremental Predictive Upshift
        if [ "$CURRENT_LEVEL_INDEX" -gt 0 ] && [ "$TASKS_COMPLETED_IN_SESSION" -ge "$THROTTLE_TASK_COUNT" ]; then
            next_level_index=$(( CURRENT_LEVEL_INDEX - 1 )); next_level_jobs=${JOBS_LEVELS[$next_level_index]}
            if [[ -n "$next_level_jobs" && -n "$CURRENT_JOBS" && "$CURRENT_JOBS" -gt 0 ]]; then
                predicted_mem_kb=$(( MEM_USED_KB * next_level_jobs / CURRENT_JOBS ))
                if [ "$predicted_mem_kb" -lt "$MEMORY_DOWNSHIFT_THRESHOLD_KB" ]; then
                    echo -e "\n\033[32;1m>> Throttle batch complete. (Prediction: OK). Attempting to upshift to j${next_level_jobs}...\033[0m"
                    KILL_REASON="UPSHIFT"; terminate_and_wait_for_pg "$NINJA_PID"; INTENTIONALLY_KILLED=true; CURRENT_LEVEL_INDEX=$next_level_index; break
                else
                    predicted_mem_gb=$(( predicted_mem_kb / 1024 / 1024 ))
                    echo -e "\n\033[33;1m!! PREDICTIVE GOVERNOR: Upshift to j${next_level_jobs} aborted.\033[0m"
                    echo -e "   \033[33m- Predicted memory (${predicted_mem_gb}GB) would exceed threshold (${MEMORY_DOWNSHIFT_THRESHOLD_GB}GB).\033[0m"
                    echo -e "   \033[33m- Staying at j${CURRENT_JOBS} for another ${THROTTLE_TASK_COUNT} tasks.\033[0m"
                    TASKS_COMPLETED_IN_SESSION=0
                fi
            else
                 echo -e "\n\033[31;1m!! GOVERNOR ERROR: Could not determine next job level. Staying at j${CURRENT_JOBS}.\033[0m"; TASKS_COMPLETED_IN_SESSION=0
            fi
        fi

        # CPU Stall Governor
        UTILIZATION=$(get_cpu_utilization); if [ "$UTILIZATION" != "-1.0" ] && [ "$(echo "$UTILIZATION < $CPU_STALL_THRESHOLD_PERCENT" | bc)" -eq 1 ]; then
            if [ "$CPU_STALL_START_TIME" -eq 0 ]; then CPU_STALL_START_TIME=$(date +%s); else
                if [ "$(( $(date +%s) - CPU_STALL_START_TIME ))" -ge "$CPU_STALL_DURATION_SEC" ]; then
                    echo -e "\n\033[33;1m!! CPU STALLED... Restarting ninja.\033[0m"; KILL_REASON="CPU_STALL"; terminate_and_wait_for_pg "$NINJA_PID"; INTENTIONALLY_KILLED=true; CPU_STALL_START_TIME=0; break
                fi
            fi
        else CPU_STALL_START_TIME=0; fi
    done

    wait $NINJA_PID 2>/dev/null; NINJA_EXIT_CODE=$?; exec 3<&-; rm -f "$PIPE_NAME"

    if [ "$INTENTIONALLY_KILLED" = true ]; then
        clean_recent_outputs
        garbage_collect_zombies

        if [[ "$KILL_REASON" == MEMORY* ]]; then
            echo -e "\033[36m>> High memory event detected. Forcing a ${FORCED_COOLDOWN_DURATION_SEC}s cooldown...\033[0m"; sleep "$FORCED_COOLDOWN_DURATION_SEC"; echo -e "   \033[32m- Cooldown complete.\033[0m"
        fi
        KILL_REASON=""; echo -e "\033[36m>> Governor intervention complete. Resuming build...\033[0m"; sleep 1; continue
    fi

    # Finalization
    if [ $NINJA_EXIT_CODE -eq 0 ]; then
        echo -e "\n*** NINJA BUILD SUCCEEDED! ***\n>> Running final packaging command..."; cd ..
        if ! "${PACKAGE_COMMAND_ARRAY[@]}" "$@"; then
            echo -e "\n*** FINAL PACKAGING FAILED. ***" >&2; exit 1
        fi
        echo -e "\n*** BUILD & PACKAGE PROCESS SUCCEEDED! ***"; break
    else
        echo -e "\n*** BUILD FAILED with a critical error (exit code $NINJA_EXIT_CODE). ***"; exit 1
    fi
done