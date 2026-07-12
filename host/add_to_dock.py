#!/usr/bin/env python3
import sys
import os
import plistlib
import subprocess
import shutil
import random
import urllib.parse

def get_cfurl_string(app_path):
    # Standard URL encoding keeping path slashes safe
    encoded_path = urllib.parse.quote(app_path, safe="/")
    return f"file://{encoded_path}/"

def check_app_in_dock(apps, cfurl_str):
    for app in apps:
        tile_data = app.get("tile-data", {})
        file_data = tile_data.get("file-data", {})
        if file_data.get("_CFURLString") == cfurl_str:
            return True
    return False

def create_dock_entry(path, label, is_dir=False):
    cfurl_str = get_cfurl_string(path)
    guid = random.randint(1000000000, 9999999999)
    if is_dir:
        return {
            "GUID": guid,
            "tile-data": {
                "file-data": {
                    "_CFURLString": cfurl_str,
                    "_CFURLStringType": 15
                },
                "file-label": label,
                "file-type": 2,
                "preferreditemsize": -1
            },
            "tile-type": "directory-tile"
        }
    else:
        return {
            "GUID": guid,
            "tile-data": {
                "file-data": {
                    "_CFURLString": cfurl_str,
                    "_CFURLStringType": 15
                },
                "file-label": label,
                "file-type": 41
            },
            "tile-type": "file-tile"
        }

def main():
    import argparse
    import pwd
    parser = argparse.ArgumentParser(description="Pin or unpin apps to macOS Dock plist safely.")
    parser.add_argument("--plist", help="Path to com.apple.dock.plist to modify")
    parser.add_argument("--kill", action="store_true", default=True, help="Restart Dock process after modification")
    parser.add_argument("--no-kill", dest="kill", action="store_false", help="Do not restart Dock process")
    parser.add_argument("--app", action="append", nargs="+", help="Add custom app path and optional label (e.g. --app '/path/to/App.app' 'App Name')")
    parser.add_argument("--remove", action="append", help="Remove an app from the Dock by its label or path")
    args = parser.parse_args()

    # Determine real host plist bypassing HOME redirection if possible
    host_plist = ""
    username = os.environ.get("USER")
    if username:
        try:
            real_home = pwd.getpwnam(username).pw_dir
            potential_plist = os.path.join(real_home, "Library/Preferences/com.apple.dock.plist")
            if os.path.exists(potential_plist):
                host_plist = potential_plist
        except KeyError:
            pass
    if not host_plist:
        host_plist = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")

    # Determine targets
    target_plists = []
    if args.plist:
        plist_path = os.path.abspath(args.plist)
        if not os.path.exists(plist_path):
            parent_dir = os.path.dirname(plist_path)
            os.makedirs(parent_dir, exist_ok=True)
            if os.path.exists(host_plist):
                print(f"Initializing Dock preferences by copying template from {host_plist}...")
                shutil.copy2(host_plist, plist_path)
        target_plists.append(plist_path)
    else:
        # Default target: active host user preferences
        if os.path.exists(host_plist):
            target_plists.append(host_plist)

    apps_to_add = []
    if args.app:
        for item in args.app:
            path = os.path.expanduser(item[0])
            if len(item) > 1:
                label = item[1]
            else:
                label = os.path.splitext(os.path.basename(path))[0]
            apps_to_add.append((path, label))
    elif not args.remove:
        # Only add default apps if --app is omitted and --remove is NOT specified
        apps_to_add = [
            ("/Applications/Antigravity.app", "Antigravity"),
            ("/Applications/Antigravity IDE.app", "Antigravity IDE")
        ]

    modified_any = False
    for plist_path in target_plists:
        if not os.path.exists(plist_path):
            print(f"Skipping {plist_path}: file does not exist.")
            continue

        print(f"Processing plist: {plist_path}...")
        try:
            with open(plist_path, "rb") as f:
                data = plistlib.load(f)
            if not isinstance(data, dict):
                print(f"Error: {plist_path} does not contain a dictionary structure. Skipping.")
                continue
        except Exception as e:
            print(f"Error reading {plist_path}: {e}")
            continue

        persistent_apps = data.get("persistent-apps", [])
        persistent_others = data.get("persistent-others", [])
        modified = False

        # 1. Handle removals first
        if args.remove:
            for rem in args.remove:
                # rem could be label or path
                rem_cfurl = get_cfurl_string(rem)
                
                initial_len_apps = len(persistent_apps)
                persistent_apps = [
                    item for item in persistent_apps
                    if item.get("tile-data", {}).get("file-label") != rem and 
                       item.get("tile-data", {}).get("file-data", {}).get("_CFURLString") != rem_cfurl
                ]
                if len(persistent_apps) < initial_len_apps:
                    modified = True
                    print(f"  - Removed '{rem}' from persistent-apps.")

                initial_len_others = len(persistent_others)
                persistent_others = [
                    item for item in persistent_others
                    if item.get("tile-data", {}).get("file-label") != rem and 
                       item.get("tile-data", {}).get("file-data", {}).get("_CFURLString") != rem_cfurl
                ]
                if len(persistent_others) < initial_len_others:
                    modified = True
                    print(f"  - Removed '{rem}' from persistent-others.")

        # 2. Handle additions
        for path, label in apps_to_add:
            if not os.path.exists(path):
                print(f"Warning: {path} does not exist on disk. Skipping.")
                continue

            is_dir = os.path.isdir(path) and not path.endswith(".app")
            target_list = persistent_others if is_dir else persistent_apps
            
            cfurl_str = get_cfurl_string(path)
            existing_entry = next((item for item in target_list if item.get("tile-data", {}).get("file-data", {}).get("_CFURLString") == cfurl_str), None)
            
            if existing_entry:
                if existing_entry.get("tile-data", {}).get("file-label") == label:
                    print(f"  - '{label}' is already pinned in the Dock.")
                else:
                    old_label = existing_entry.get("tile-data", {}).get("file-label")
                    existing_entry["tile-data"]["file-label"] = label
                    modified = True
                    print(f"  * Updated label for '{path}': '{old_label}' -> '{label}'")
            else:
                entry = create_dock_entry(path, label, is_dir=is_dir)
                target_list.append(entry)
                modified = True
                print(f"  + Added '{label}' to the Dock plist.")

        if modified:
            data["persistent-apps"] = persistent_apps
            data["persistent-others"] = persistent_others
            try:
                with open(plist_path, "wb") as f:
                    plistlib.dump(data, f)
                print(f"Successfully updated: {plist_path}")
                modified_any = True
                is_host_user_plist = plist_path.endswith("/Library/Preferences/com.apple.dock.plist")
                if is_host_user_plist and args.kill:
                    print("Flushing preferences cache and restarting Dock process to apply changes...")
                    try:
                        subprocess.run(["killall", "cfprefsd"], check=True)
                        subprocess.run(["defaults", "read", "com.apple.dock"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        subprocess.run(["killall", "Dock"], check=True)
                    except Exception as err:
                        print(f"Warning: Failed to flush preferences / restart Dock: {err}")
            except Exception as e:
                print(f"Error writing to {plist_path}: {e}")

if __name__ == "__main__":
    main()
