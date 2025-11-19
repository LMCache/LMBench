# SPDX-License-Identifier: Apache-2.0
import json
import argparse

def main():
    parser = argparse.ArgumentParser(description="Process ShareGPT JSON file and build 'input' and 'output_length' fields for conversation entries.")
    parser.add_argument("--limit", type=int, default=1000, help="Number of entries to process (default: 1000)")
    args = parser.parse_args()
    
    with open('ShareGPT.json', 'r') as f:
        data = json.load(f)

    # Process only the first args.limit entries and build the "input" and "output_length" fields.
    for entry in data[:args.limit]:
        conversation = entry.get("conversations", [])
        cumulative_text = ""
        human_count = 0

        # Iterate over conversation with an index so we can look ahead.
        for i, msg in enumerate(conversation):
            cumulative_text += msg["value"] + "\n"  # Append message text with a newline

            # When a human message is encountered, save the cumulative text and determine the output_length.
            if msg.get("from", "").lower() == "human":
                human_count += 1
                input_field_name = "input" if human_count == 1 else f"input{human_count}"
                entry[input_field_name] = cumulative_text.strip()

                # Find the next GPT message after this human message.
                output_length = 20  # default value if no GPT response is found
                for j in range(i + 1, len(conversation)):
                    next_msg = conversation[j]
                    if next_msg.get("from", "").lower() == "gpt":
                        output_length = next_msg.get("num_tokens", 20)
                        break

                output_field_name = "output_length" if human_count == 1 else f"output_length{human_count}"
                entry[output_field_name] = output_length

    # Create a new list where each entry only contains the desired fields.
    new_data = []
    for entry in data[:args.limit]:
        new_entry = {}
        # Keep num_round if it exists.
        if "num_round" in entry:
            new_entry["num_round"] = entry["num_round"]
        # Keep keys that start with "input" or "output_length"
        for key, value in entry.items():
            if key.startswith("input") or key.startswith("output_length"):
                new_entry[key] = value
        new_data.append(new_entry)

    with open('modified_file.json', 'w') as f:
        json.dump(new_data, f, indent=2)

if __name__ == "__main__":
    main()
