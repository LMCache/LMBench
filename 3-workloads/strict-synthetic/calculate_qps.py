#!/usr/bin/env python3
"""
Simple script to calculate QPS for strict-synthetic workload
QPS = NUM_CONCURRENT_USERS / TIME_BETWEEN_REQUESTS_PER_USER
"""
import sys

def main():
    if len(sys.argv) != 3:
        print("Usage: python3 calculate_qps.py <num_concurrent_users> <time_between_requests_per_user>", file=sys.stderr)
        sys.exit(1)
    
    try:
        num_concurrent_users = float(sys.argv[1])
        time_between_requests_per_user = float(sys.argv[2])
        
        if time_between_requests_per_user == 0:
            print("Error: time_between_requests_per_user cannot be zero", file=sys.stderr)
            sys.exit(1)
        
        qps = num_concurrent_users / time_between_requests_per_user
        print(f"{qps:.2f}")
        
    except ValueError as e:
        print(f"Error: Invalid numeric input - {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main() 