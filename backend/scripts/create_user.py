import argparse
import getpass
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.dirname(SCRIPT_DIR)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from auth_utils import hash_password  # noqa: E402
from database import db  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Create an invite-only myMusic user.")
    parser.add_argument("--username", required=True, help="Username for the new account")
    parser.add_argument("--password", help="Password (omit to prompt securely)")
    args = parser.parse_args()

    username = args.username.strip()
    if not username:
        raise SystemExit("Username cannot be empty.")

    password = args.password or getpass.getpass("Password: ")
    if len(password) < 6:
        raise SystemExit("Password must be at least 6 characters.")

    existing = db.get_user_by_username(username)
    if existing:
        raise SystemExit(f"User '{username}' already exists.")

    user = db.create_user(username=username, password_hash=hash_password(password))
    print(f"Created user id={user['id']} username={user['username']}")


if __name__ == "__main__":
    main()
