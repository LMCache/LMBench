# SPDX-License-Identifier: Apache-2.0
import argparse
import json

# Set up argument parsing for the two numeric parameters.
parser = argparse.ArgumentParser(
    description="Filter entries by a minimum number of rounds and extract a specific round's data."
)
parser.add_argument(
    '--min_rounds', type=int, default=5,
    help='Minimum number of rounds required to include an entry (default: 5)'
)
parser.add_argument(
    '--round_number', type=int, default=2,
    help='The round number from which to extract data (default: 2)'
)
args = parser.parse_args()

# Load the JSON data from the fixed input file.
with open('modified_file.json', 'r') as f:
    data = json.load(f)

# Filter out entries with less than the specified minimum rounds.
filtered_data = []
for entry in data:
    # Count keys that are "input" or "inputN" (where N is a number)
    round_count = sum(1 for key in entry if key == "input" or (key.startswith("input") and key[5:].isdigit()))
    if round_count >= args.min_rounds:
        filtered_data.append(entry)

# (Optional) Determine the maximum number of rounds among the filtered entries.
max_round = 0
for entry in filtered_data:
    round_count = sum(1 for key in entry if key == "input" or (key.startswith("input") and key[5:].isdigit()))
    if round_count > max_round:
        max_round = round_count

# Build a new list to store results extracted from the chosen round.
new_data = []
for entry in filtered_data:
    input_field = f"input{args.round_number}"
    output_field = f"output_length{args.round_number}"
    if input_field in entry:
        new_entry = {"input": entry[input_field]}
        # Include output_length if present; if not, default to 20.
        new_entry["output_length"] = entry.get(output_field, 20)
        new_data.append(new_entry)

# Write the new JSON list to a fixed output file.
with open('warmup.json', 'w') as f:
    json.dump(new_data, f, indent=2)
