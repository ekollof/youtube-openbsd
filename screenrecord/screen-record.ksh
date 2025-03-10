#!/bin/ksh

# Help message
usage() {
    echo "Usage: $0 [-s screen] [-l] [-h] [-c config] [-b bitrate] [-n] [-d] [-m]"
    echo "  -s screen   Select screen number (0, 1, 2, etc.)"
    echo "  -l         List available screens"
    echo "  -h         Show this help message"
    echo "  -c config  Source configuration file for streaming (sets RTMP_URI and STREAM_KEY)"
    echo "  -b bitrate Video bitrate in kbps (default: 8000, YouTube 1080p60 recommendation)"
    echo "  -n         Enable noise gate on mic input"
    echo "  -d         Enable noise suppression on mic input"
    echo "  -m         Measure ambient noise to tune noise gate (requires -n)"
    echo "Press 'q' or Ctrl+C to stop streaming cleanly."
    exit 1
}

# Function to list screens with xrandr
list_screens() {
    echo "Available screens:"
    xrandr --listactivemonitors | tail -n +2 | nl -v 0
}

# Function to get screen geometry for a given screen number
get_screen_geometry() {
    screen_num=$1
    echo "Debug: Looking for screen $screen_num"
    
    monitor_info=$(xrandr --listactivemonitors | tail -n +2 | sed -n "$((screen_num + 1))p")
    echo "Debug: Monitor info: $monitor_info"
    
    if [ -z "$monitor_info" ]; then
        echo "Error: Screen $screen_num not found" >&2
        exit 1
    fi

    raw_info=$(xrandr | grep -A1 "^Screen" | tail -n1)
    echo "Debug: Raw screen info: $raw_info"

    current_mode=$(xrandr | grep -A1 "^$(echo "$monitor_info" | awk '{print $3}')" | grep -v "^--" | grep "*" | awk '{print $1}')
    echo "Debug: Current mode: $current_mode"

    if [ -n "$current_mode" ]; then
        SCREEN_WIDTH=$(echo "$current_mode" | cut -d'x' -f1)
        SCREEN_HEIGHT=$(echo "$current_mode" | cut -d'x' -f2)
    else
        SCREEN_WIDTH=$(echo "$monitor_info" | awk '{print $3}' | cut -d'/' -f1)
        SCREEN_HEIGHT=$(echo "$monitor_info" | awk '{print $3}' | cut -d'x' -f2 | cut -d'/' -f1)
    fi

    SCREEN_OFFSET_X=$(echo "$monitor_info" | awk '{print $3}' | sed 's/.*+\([0-9]*\)+.*/\1/')
    SCREEN_OFFSET_Y=$(echo "$monitor_info" | awk '{print $3}' | sed 's/.*+[0-9]*+\([0-9]*\)/\1/')

    echo "Debug: Parsed values:"
    echo "Width: $SCREEN_WIDTH"
    echo "Height: $SCREEN_HEIGHT"
    echo "Offset X: $SCREEN_OFFSET_X"
    echo "Offset Y: $SCREEN_OFFSET_Y"

    if [ -z "$SCREEN_WIDTH" ] || [ -z "$SCREEN_HEIGHT" ] || \
       [ -z "$SCREEN_OFFSET_X" ] || [ -z "$SCREEN_OFFSET_Y" ]; then
        echo "Error: Failed to parse screen dimensions" >&2
        exit 1
    fi
}

# Function to source config file
source_config() {
    config_file=$1
    if [ -f "$config_file" ]; then
        . "$config_file"
    else
        echo "Error: Config file $config_file not found" >&2
        exit 1
    fi
}

# Function to detect VAAPI support
detect_vaapi() {
    if command -v vainfo >/dev/null 2>&1; then
        if vainfo | grep -q "VAProfileH264"; then
            echo "VAAPI hardware acceleration detected, using h264_vaapi."
            USE_VAAPI="yes"
        else
            echo "VAAPI detected but no H.264 support, falling back to libx264."
            USE_VAAPI="no"
        fi
    else
        echo "vainfo not found, falling back to software encoding with libx264."
        USE_VAAPI="no"
    fi
}

# Function to measure ambient noise and suggest noise gate threshold
measure_noise() {
    echo "Recording 5 seconds of ambient noise to tune noise gate... Please remain silent."
    ffmpeg -f sndio -i snd/0 -t 5 -af "volumedetect" -f null /dev/null 2> noise_stats.txt
    MEAN_VOLUME=$(grep "mean_volume" noise_stats.txt | awk '{print $5}')
    MAX_VOLUME=$(grep "max_volume" noise_stats.txt | awk '{print $5}')
    rm -f noise_stats.txt

    if [ -z "$MEAN_VOLUME" ] || [ -z "$MAX_VOLUME" ]; then
        echo "Error: Could not detect noise levels, using default threshold (-50dB)." >&2
        NOISE_THRESHOLD="-50"
    else
        NOISE_THRESHOLD=$(echo "$MEAN_VOLUME + 10" | bc)
        if [ $(echo "$NOISE_THRESHOLD > $MAX_VOLUME" | bc) -eq 1 ]; then
            NOISE_THRESHOLD=$(echo "$MAX_VOLUME - 5" | bc)
        fi
        if [ $(echo "$NOISE_THRESHOLD > -10" | bc) -eq 1 ]; then
            NOISE_THRESHOLD="-10"
        fi
        echo "Detected noise levels: Mean = $MEAN_VOLUME dB, Max = $MAX_VOLUME dB"
        echo "Suggested noise gate threshold: ${NOISE_THRESHOLD}dB"
    fi
}

# Function to monitor FFmpeg stats for buffer health
monitor_buffers() {
    STATS_FILE="$1"
    echo "Starting buffer monitoring for $STATS_FILE (FFmpeg PID: $FFMPEG_PID)"
    LAST_FRAMES=0
    LAST_TIME=0
    while ps -p "$FFMPEG_PID" >/dev/null 2>&1; do
        if [ -s "$STATS_FILE" ]; then
            FRAME=$(grep "^frame=" "$STATS_FILE" | tail -n1 | cut -d'=' -f2)
            SIZE=$(grep "^total_size=" "$STATS_FILE" | tail -n1 | cut -d'=' -f2)
            TIME=$(grep "^out_time=" "$STATS_FILE" | tail -n1 | cut -d'=' -f2)
            BITRATE=$(grep "^bitrate=" "$STATS_FILE" | tail -n1 | cut -d'=' -f2)
            SPEED=$(grep "^speed=" "$STATS_FILE" | tail -n1 | cut -d'=' -f2 | sed 's/x$//')
            DROP=$(grep "^drop_frames=" "$STATS_FILE" | tail -n1 | cut -d'=' -f2)

            FRAME=${FRAME:-0}
            SIZE=${SIZE:-0}
            TIME=${TIME:-00:00:00.000000}
            BITRATE=${BITRATE:-0kbits/s}
            SPEED=${SPEED:-0}
            DROP=${DROP:-0}

            TIME_SECS=$(echo "$TIME" | awk -F: '{print ($1*3600)+($2*60)+$3}')
            if [ "$LAST_TIME" != "0" ] && [ "$TIME_SECS" != "$LAST_TIME" ]; then
                FPS=$(echo "($FRAME - $LAST_FRAMES) / ($TIME_SECS - $LAST_TIME)" | bc 2>/dev/null)
            else
                FPS=0
            fi
            LAST_FRAMES=$FRAME
            LAST_TIME=$TIME_SECS

            if [ "$SPEED" = "N/A" ]; then
                SPEED=0
            fi

            echo "Buffer Status: Frames=$FRAME, FPS=$FPS, Dropped=$DROP, Speed=${SPEED}x, Bitrate=$BITRATE, Size=$SIZE bytes, Time=$TIME"
            if [ "$DROP" -gt 0 ]; then
                echo "Warning: Frames are being dropped, buffers may be overflowing."
            fi
            if [ "$SPEED" != "0" ] && [ $(echo "$SPEED < 0.9" | bc 2>/dev/null) -eq 1 ]; then
                echo "Warning: Encoding speed below 0.9x, system may be overloaded."
            fi
        fi
        sleep 5
    done
    echo "FFmpeg process ended, stopping monitoring."
}

# Cleanup function for clean exit
cleanup() {
    echo "Stopping streaming..."
    if [ -n "$FFMPEG_PID" ]; then
        kill -INT "$FFMPEG_PID"  # Send SIGINT (like 'q') to FFmpeg
        wait "$FFMPEG_PID" 2>/dev/null  # Wait for it to finish
    fi
    rm -f "$STATS_FILE" "$LOG_FILE"  # Clean up stats and log files
    echo "Streaming stopped cleanly."
    exit 0
}

# Trap Ctrl+C (SIGINT) to call cleanup
trap cleanup INT

# Initialize variables
SCREEN=""
SCREEN_WIDTH=""
SCREEN_HEIGHT=""
SCREEN_OFFSET_X=""
SCREEN_OFFSET_Y=""
RTMP_URI=""
STREAM_KEY=""
USE_VAAPI=""
BITRATE="8000"  # Default to 8000 kbps (YouTube 1080p60 recommendation)
NOISE_GATE="no"
NOISE_DENOISE="no"
MEASURE_NOISE="no"
NOISE_THRESHOLD="-50"  # Default noise gate threshold in dB
FFMPEG_PID=""
STATS_FILE=""
LOG_FILE=""

# Parse command line options
while getopts "s:lhc:b:ndm" opt; do
    case $opt in
        s)
            SCREEN=${OPTARG}
            get_screen_geometry "$SCREEN"
            ;;
        l)
            list_screens
            exit 0
            ;;
        h)
            usage
            ;;
        c)
            source_config "${OPTARG}"
            ;;
        b)
            BITRATE=${OPTARG}
            ;;
        n)
            NOISE_GATE="yes"
            echo "Noise gate enabled."
            ;;
        d)
            NOISE_DENOISE="yes"
            echo "Noise suppression enabled."
            ;;
        m)
            MEASURE_NOISE="yes"
            echo "Noise measurement enabled."
            ;;
        *)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
    esac
done

# If no screen specified or geometry not set, show usage
if [ -z "$SCREEN" ] || [ -z "$SCREEN_WIDTH" ]; then
    echo "Error: No screen selected or screen geometry not found" >&2
    usage
fi

# If streaming but no RTMP_URI or STREAM_KEY, require config
if [ -n "$RTMP_URI" ] && [ -z "$STREAM_KEY" ] || [ -z "$RTMP_URI" ] && [ -n "$STREAM_KEY" ]; then
    echo "Error: Both RTMP_URI and STREAM_KEY must be set in config file for streaming (use -c)" >&2
    usage
fi

# If -m is used without -n, warn and disable measurement
if [ "$MEASURE_NOISE" = "yes" ] && [ "$NOISE_GATE" != "yes" ]; then
    echo "Warning: -m (measure noise) requires -n (noise gate). Ignoring -m." >&2
    MEASURE_NOISE="no"
fi

# Measure noise if requested
if [ "$MEASURE_NOISE" = "yes" ]; then
    measure_noise
fi

# Detect VAAPI support
detect_vaapi

# Get current timestamp
NAME=$(date '+%Y-%m-%d_%H%M%S')

echo "Recording screen $SCREEN (${SCREEN_WIDTH}x${SCREEN_HEIGHT} at offset ${SCREEN_OFFSET_X},${SCREEN_OFFSET_Y})"
echo "Using video bitrate: ${BITRATE} kbps"

# Determine output destination
if [ -n "$RTMP_URI" ] && [ -n "$STREAM_KEY" ]; then
    OUTPUT="$RTMP_URI/$STREAM_KEY"
    echo "STREAMING to $OUTPUT"
else
    OUTPUT="$HOME/Videos/$NAME.mkv"
fi

# Build the mic filter chain dynamically based on options
MIC_FILTER="[1:a]pan=mono|c0=c1"
if [ "$NOISE_GATE" = "yes" ]; then
    MIC_FILTER="$MIC_FILTER,agate=threshold=${NOISE_THRESHOLD}dB:attack=20:release=250"
fi
if [ "$NOISE_DENOISE" = "yes" ]; then
    MIC_FILTER="$MIC_FILTER,afftdn=nr=12"
fi
MIC_FILTER="$MIC_FILTER,volume=3.0,acompressor=threshold=0.125:ratio=4:attack=200:release=1000,dynaudnorm=f=50:g=5:p=0.9[mic]"

# Define the full filter complex string
FILTER_COMPLEX="[0:a]volume=4.0[desktop];$MIC_FILTER;[desktop][mic]amix=inputs=2:duration=first[aout];[aout]aresample=async=1[finalaudio]"

# Set stats and log files
STATS_FILE="/tmp/ffmpeg_progress_$$.txt"
LOG_FILE="/tmp/ffmpeg_log_$$.txt"

# Execute FFmpeg based on VAAPI detection with progress output
echo "Press 'q' or Ctrl+C to stop streaming."
if [ "$USE_VAAPI" = "yes" ]; then
    ffmpeg \
        -hwaccel vaapi -vaapi_device /dev/dri/renderD128 \
        -f sndio -thread_queue_size 16384 -i snd/0.mon \
        -f sndio -thread_queue_size 32768 -i snd/0 \
        -f x11grab -thread_queue_size 128 -probesize 32M -draw_mouse 1 \
        -video_size "${SCREEN_WIDTH}x${SCREEN_HEIGHT}" -r 60 \
        -i ":0.0+${SCREEN_OFFSET_X},${SCREEN_OFFSET_Y}" \
        -filter_complex "$FILTER_COMPLEX" \
        -map 2:v \
        -map '[finalaudio]' \
        -c:v h264_vaapi \
        -vf 'format=nv12|vaapi,hwupload' \
        -b:v "${BITRATE}k" -rc_mode CBR \
        -c:a aac \
        -b:a 160k \
        -ar 48000 \
        -ac 2 \
        -fps_mode cfr \
        -flags +low_delay \
        -fflags +nobuffer \
        -use_wallclock_as_timestamps 1 \
        -progress "$STATS_FILE" \
        -f flv -loglevel warning -hide_banner \
        -y \
        "$OUTPUT" 2>"$LOG_FILE" &
else
    ffmpeg \
        -f sndio -thread_queue_size 16384 -i snd/0.mon \
        -f sndio -thread_queue_size 32768 -i snd/0 \
        -f x11grab -thread_queue_size 128 -probesize 32M -draw_mouse 1 \
        -video_size "${SCREEN_WIDTH}x${SCREEN_HEIGHT}" -r 60 \
        -i ":0.0+${SCREEN_OFFSET_X},${SCREEN_OFFSET_Y}" \
        -filter_complex "$FILTER_COMPLEX" \
        -map 2:v \
        -map '[finalaudio]' \
        -c:v libx264 \
        -crf 23 \
        -preset ultrafast \
        -b:v "${BITRATE}k" \
        -c:a aac \
        -b:a 160k \
        -ar 48000 \
        -ac 2 \
        -fps_mode cfr \
        -flags +low_delay \
        -fflags +nobuffer \
        -use_wallclock_as_timestamps 1 \
        -progress "$STATS_FILE" \
        -f flv -loglevel warning -hide_banner \
        -y \
        "$OUTPUT" 2>"$LOG_FILE" &
fi

# Store the FFmpeg PID
FFMPEG_PID=$!

# Check if FFmpeg started successfully
sleep 1  # Give FFmpeg a moment to start
if ! ps -p "$FFMPEG_PID" >/dev/null 2>&1; then
    echo "Error: FFmpeg failed to start. Check $LOG_FILE for details:"
    cat "$LOG_FILE"
    cleanup
fi

# Start buffer monitoring in the foreground
monitor_buffers "$STATS_FILE"

# Cleanup after FFmpeg exits naturally
cleanup
