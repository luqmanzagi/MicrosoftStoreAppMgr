import json
import os

# Read the input JSON file
input_file = 'result/apps_free.json'
output_dir = 'result'

# Ensure output directory exists
os.makedirs(output_dir, exist_ok=True)

# Load the JSON data
with open(input_file, 'r', encoding='utf-8') as f:
    apps = json.load(f)

# Split into chunks of 20
chunk_size = 20
num_chunks = (len(apps) + chunk_size - 1) // chunk_size  # Ceiling division

print(f"Total apps: {len(apps)}")
print(f"Creating {num_chunks} chunks of {chunk_size} apps each")

# Process each chunk
for chunk_num in range(num_chunks):
    start_idx = chunk_num * chunk_size
    end_idx = min(start_idx + chunk_size, len(apps))
    chunk = apps[start_idx:end_idx]
    
    # Extract IDs and names
    app_ids = [app['itemID'] for app in chunk]
    app_names = [app['itemName'] for app in chunk]
    
    # Create file numbers (1-indexed)
    file_num = chunk_num + 1
    
    # Write ID file - one ID per line
    id_filename = os.path.join(output_dir, f'app_ID_{file_num}.txt')
    with open(id_filename, 'w', encoding='utf-8') as f:
        for app_id in app_ids:
            f.write(f"{app_id}\n")
    
    # Write name file - one name per line
    name_filename = os.path.join(output_dir, f'app_name_{file_num}.txt')
    with open(name_filename, 'w', encoding='utf-8') as f:
        for app_name in app_names:
            f.write(f"{app_name}\n")
    
    print(f"Created chunk {file_num}: {len(chunk)} apps (indices {start_idx} to {end_idx-1})")

print(f"\nDone! Created {num_chunks * 2} files in '{output_dir}' directory")
