#!/usr/bin/env python3
"""Strip non-English audio tracks from MKV files to save space (lossless)"""

import subprocess
import sys
import os
import json
import shutil

def get_streams(filepath):
    """Get stream info from file"""
    cmd = ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams', filepath]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(result.stdout).get('streams', [])

def strip_audio(input_file, dry_run=False):
    """Strip non-English audio tracks, keeping video and subs intact"""
    
    streams = get_streams(input_file)
    
    # Categorize streams
    video_streams = []
    english_audio = []
    other_audio = []
    subtitle_streams = []
    
    for i, s in enumerate(streams):
        codec_type = s.get('codec_type', '')
        lang = s.get('tags', {}).get('language', 'und').lower()
        
        if codec_type == 'video':
            video_streams.append(i)
        elif codec_type == 'audio':
            if lang in ['eng', 'en', 'english', 'und']:
                english_audio.append(i)
            else:
                other_audio.append((i, lang, s.get('codec_name', '?')))
        elif codec_type == 'subtitle':
            subtitle_streams.append(i)
    
    if not other_audio:
        print(f"  No non-English audio to remove")
        return False
    
    # Calculate potential savings (rough estimate)
    print(f"  Video streams: {len(video_streams)}")
    print(f"  English audio: {len(english_audio)}")
    print(f"  Other audio to REMOVE: {len(other_audio)}")
    for idx, lang, codec in other_audio:
        print(f"    - Stream {idx}: {lang} ({codec})")
    print(f"  Subtitles: {len(subtitle_streams)}")
    
    if dry_run:
        return True
    
    # Build ffmpeg command
    output_file = input_file.rsplit('.', 1)[0] + '.stripped.mkv'
    
    cmd = ['ffmpeg', '-i', input_file, '-map', '0:v']
    
    # Map English audio
    for idx in english_audio:
        cmd.extend(['-map', f'0:{idx}'])
    
    # Map all subtitles
    cmd.extend(['-map', '0:s?'])
    
    # Copy without re-encoding
    cmd.extend(['-c', 'copy', output_file])
    
    print(f"  Running ffmpeg...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode == 0:
        # Verify output
        old_size = os.path.getsize(input_file)
        new_size = os.path.getsize(output_file)
        saved = (old_size - new_size) / 1073741824
        
        print(f"  Original: {old_size/1073741824:.1f} GB")
        print(f"  New:      {new_size/1073741824:.1f} GB")
        print(f"  Saved:    {saved:.1f} GB")
        
        # Replace original
        os.remove(input_file)
        shutil.move(output_file, input_file)
        print(f"  ✓ Replaced original file")
        return True
    else:
        print(f"  ERROR: {result.stderr[:200]}")
        if os.path.exists(output_file):
            os.remove(output_file)
        return False

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: strip-audio-tracks.py <file.mkv> [--dry-run]")
        sys.exit(1)
    
    filepath = sys.argv[1]
    dry_run = '--dry-run' in sys.argv
    
    if dry_run:
        print(f"DRY RUN - Analyzing: {os.path.basename(filepath)}")
    else:
        print(f"Processing: {os.path.basename(filepath)}")
    
    strip_audio(filepath, dry_run)
