import json
import os
import sys

# Get the group size from command line argument
if len(sys.argv) < 2:
    print("Usage: python group_of_n.py <n>")
    print("Example: python group_of_n.py 20")
    sys.exit(1)

try:
    n = int(sys.argv[1])
    if n <= 0:
        print("Error: n must be a positive integer")
        sys.exit(1)
except ValueError:
    print("Error: n must be a valid integer")
    sys.exit(1)

# Read the input JSON file
input_file = '../result/apps_free.json'
output_dir = '../result'

# Ensure output directory exists
os.makedirs(output_dir, exist_ok=True)

# Load the JSON data
try:
    with open(input_file, 'r', encoding='utf-8') as f:
        apps = json.load(f)
except FileNotFoundError:
    print(f"Error: File '{input_file}' not found")
    sys.exit(1)
except json.JSONDecodeError:
    print(f"Error: Invalid JSON in '{input_file}'")
    sys.exit(1)

# Split into chunks of n
chunk_size = n
num_chunks = (len(apps) + chunk_size - 1) // chunk_size  # Ceiling division

print(f"Total apps: {len(apps)}")
print(f"Creating {num_chunks} groups of {chunk_size} apps each")

# Process each chunk
for chunk_num in range(num_chunks):
    start_idx = chunk_num * chunk_size
    end_idx = min(start_idx + chunk_size, len(apps))
    chunk = apps[start_idx:end_idx]
    
    # Create file numbers (1-indexed)
    file_num = chunk_num + 1
    
    # Write app file - JSON format with full app objects
    app_filename = os.path.join(output_dir, f'app_{file_num}.json')
    with open(app_filename, 'w', encoding='utf-8') as f:
        json.dump(chunk, f, indent=2, ensure_ascii=False)
    
    print(f"Created group {file_num}: {len(chunk)} apps (indices {start_idx} to {end_idx-1})")

print(f"\nDone! Created {num_chunks} files in '{output_dir}' directory")

