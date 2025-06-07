#!/usr/bin/env python3

import requests
import json
import os
import sys
from pathlib import Path
from typing import Optional

def upload_json_file(json_file_path: str, api_url: str = "http://localhost:3001/upload") -> bool:
    """
    Upload a single JSON file to the API endpoint.

    Args:
        json_file_path: Path to the JSON file to upload
        api_url: API endpoint URL

    Returns:
        True if upload successful, False otherwise
    """
    try:
        if not os.path.exists(json_file_path):
            print(f"❌ File not found: {json_file_path}")
            return False

        # Extract filename for the upload
        filename = os.path.basename(json_file_path)

        with open(json_file_path, 'rb') as f:
            files = {'file': (filename, f, 'application/json')}

            print(f"📤 Uploading {filename}...")
            response = requests.post(api_url, files=files, timeout=30)

            if response.status_code == 200:
                print(f"✅ Upload successful: {filename}")
                result = response.json()
                print(f"   Suite: {result.get('parsed_data', {}).get('suite_name', 'unknown')}")
                print(f"   Baseline: {result.get('parsed_data', {}).get('baseline_key', 'unknown')}")
                print(f"   Workload: {result.get('parsed_data', {}).get('workload_type', 'unknown')}")
                return True
            else:
                print(f"❌ Upload failed for {filename}: {response.status_code}")
                print(f"   Error: {response.text}")
                return False

    except requests.exceptions.RequestException as e:
        print(f"❌ Network error uploading {json_file_path}: {str(e)}")
        return False
    except Exception as e:
        print(f"❌ Error uploading {json_file_path}: {str(e)}")
        return False

def upload_directory(directory_path: str, api_url: str = "http://localhost:3001/upload") -> tuple[int, int]:
    """
    Upload all JSON files in a directory to the API endpoint.

    Args:
        directory_path: Path to directory containing JSON files
        api_url: API endpoint URL

    Returns:
        Tuple of (successful_uploads, total_files)
    """
    if not os.path.exists(directory_path):
        print(f"❌ Directory not found: {directory_path}")
        return 0, 0

    json_files = list(Path(directory_path).glob("*.json"))

    if not json_files:
        print(f"📁 No JSON files found in {directory_path}")
        return 0, 0

    print(f"📁 Found {len(json_files)} JSON files in {directory_path}")

    successful = 0
    for json_file in json_files:
        if upload_json_file(str(json_file), api_url):
            successful += 1

    return successful, len(json_files)

def test_api_connection(api_url: str = "http://localhost:3001") -> bool:
    """Test if the API is reachable."""
    try:
        response = requests.get(f"{api_url}/health", timeout=10)
        if response.status_code == 200:
            print(f"✅ API is reachable at {api_url}")
            return True
        else:
            print(f"❌ API returned status {response.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Cannot reach API at {api_url}: {str(e)}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python upload_to_api.py <json_file_or_directory> [api_url]")
        print("  python upload_to_api.py test [api_url]  # Test API connection")
        print("")
        print("Examples:")
        print("  python upload_to_api.py results.json")
        print("  python upload_to_api.py /path/to/results/")
        print("  python upload_to_api.py test")
        sys.exit(1)

    target = sys.argv[1]
    api_url = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:3001/upload"

    # Extract base URL for health check
    base_url = api_url.replace("/upload", "") if api_url.endswith("/upload") else api_url

    if target == "test":
        test_api_connection(base_url)
        sys.exit(0)

    # Test API connection first
    if not test_api_connection(base_url):
        print("❌ API connection failed. Exiting.")
        sys.exit(1)

    if os.path.isfile(target):
        # Upload single file
        success = upload_json_file(target, api_url)
        sys.exit(0 if success else 1)
    elif os.path.isdir(target):
        # Upload directory
        successful, total = upload_directory(target, api_url)
        print(f"\n📊 Upload summary: {successful}/{total} files uploaded successfully")
        sys.exit(0 if successful == total else 1)
    else:
        print(f"❌ Path not found: {target}")
        sys.exit(1)