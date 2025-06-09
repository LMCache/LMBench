import argparse
import json

# Set up argument parsing for dynamic configuration of rounds.
parser = argparse.ArgumentParser(
    description="Filter entries with a minimum number of rounds and perform a round-robin transformation."
)
parser.add_argument(
    '--min_rounds', type=int, default=5,
    help='Minimum number of rounds required to include an entry (default: 5)'
)
parser.add_argument(
    '--start_round', type=int, default=3,
    help='The round number from which to start processing (default: 3)'
)
args = parser.parse_args()

# Load the JSON data from the fixed input file.
with open('modified_file.json', 'r') as f:
    data = json.load(f)

# Filter out entries with fewer than the specified number of rounds.
filtered_data = []
for entry in data:
    # Count keys that are "input" or "inputN" (where N is a number)
    round_count = sum(
        1 for key in entry
        if key == "input" or (key.startswith("input") and key[5:].isdigit())
    )
    if round_count >= args.min_rounds:
        filtered_data.append(entry)

# Determine the maximum number of rounds among the filtered entries.
max_round = 0
for entry in filtered_data:
    round_count = sum(
        1 for key in entry
        if key == "input" or (key.startswith("input") and key[5:].isdigit())
    )
    if round_count > max_round:
        max_round = round_count

# Build a new list to store conversation-based results.
new_data = []

# Instead of round-robin, group by conversation to preserve session structure
conversation_id = 0
for entry in filtered_data:
    # Count how many rounds this conversation has
    round_count = sum(
        1 for key in entry
        if key == "input" or (key.startswith("input") and key[5:].isdigit())
    )

    # Create requests for each round of this conversation, starting from start_round
    for round_num in range(max(1, args.start_round), min(round_count + 1, args.min_rounds + 1)):
        input_field = "input" if round_num == 1 else f"input{round_num}"
        output_field = "output_length" if round_num == 1 else f"output_length{round_num}"

        if input_field in entry:
            new_entry = {
                "input": entry[input_field],
                "output_length": entry.get(output_field, 20),
                "conversation_id": conversation_id,  # Same ID for all rounds in this conversation
                "round_num": round_num
            }
            new_data.append(new_entry)

    conversation_id += 1

# Write the new JSON list to the fixed output file.
with open('run.json', 'w') as f:
    json.dump(new_data, f, indent=2)
