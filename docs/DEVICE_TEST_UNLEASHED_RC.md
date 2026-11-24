# Device test: HCG Terminal Unleashed release candidates on iPhone 11 Pro Max

**This is the release gate.** HCG Repo publication waits for a passing run of this checklist and the owner's explicit approval.

| | |
|---|---|
| Device | iPhone 11 Pro Max (test device) |
| iOS | 17.4 |
| Jailbreak | Dopamine 2.x, rootless (`/var/jb`) |
| Package manager | Zebra 1.1.x (repeat the install with Sileo if it is installed) |
| Package | The candidate under test, from HCG Repo Candidate (Zebra or Sileo) |
| Expected SHA-256 | The SHA-256 given in that candidate's approval request (0.2.0~rc1: `02626804…fc5a28`, did not launch) |

Record for every step: **Pass / Fail / Not run**, plus a screenshot or a note. Stop at the first failure in sections A–C and report it.

## A. Before installing (backup and baseline)
1. Confirm iOS 17.4 and that the jailbreak is active: Dopamine shows *Jailbroken* and Zebra opens.
2. Back up:
   - the package selections: run `dpkg --get-selections > /var/mobile/dpkg-selections-before.txt` in an SSH or NewTerm session;
   - Zebra's source list: Zebra → Sources → share/export, or copy `/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list`.
3. Note free space: Settings → General → iPhone Storage.
4. Remove any sideloaded *HCG Terminal Unleashed* (Xcode, IPA, TrollStore). It uses the same bundle ID. The App Store *HCG Terminal* may stay installed; record that it does.
5. Note whether Tweak Injection is on in the Dopamine app.

## B. Install
6. Copy the `.deb` to the phone (AirDrop to Filza, or `scp` over SSH).
7. Check the checksum on the phone: `shasum -a 256 <file>.deb` (or `sha256sum`). It must equal the expected SHA-256.
8. Install with Filza → *Install*, or run `sudo dpkg -i <file>.deb`. Expected:
   - no errors;
   - `uicache` output from `postinst`;
   - the icon *HCG Terminal Unleashed* appears.

   If dpkg complains about `uikittools`, run `sudo apt install uikittools` first. Installing it is your choice; HCG Terminal does not do it for you.
9. Run `dpkg -s com.hakmicapitalgroup.hcgterminal.unleashed`. It should show `Status: install ok installed` and `Version: 0.2.0~rc1`.
10. Run `ls -l /var/jb/Applications/HCGTerminalUnleashed.app/hcg-pty-helper`. It should be an executable (`-rwxr-xr-x`) owned by root.

## C. First launch and diagnostics
11. Open the app. It must open its interface without crashing.
    - If it closes at once, open it a second time: from 0.2.0~rc2 it shows *Startup Recovery*. Share the startup report, then try *Start in Safe Mode*.
    - Collect the evidence in docs/JAILBREAK_EDITION.md → *Collecting evidence from the device*.
12. Unleashed Tools → **Jailbreak Diagnostics**:
    - *Install location* OK, path under `/var/jb/Applications`;
    - *Signature and entitlements* OK, "ad hoc / ldid signature; outside the app sandbox";
    - *Controlling-terminal helper* OK;
    - *Outside the sandbox* OK.
13. Same screen: *Jailbreak root* shows `/var/jb → /private/preboot/…`. Markers include `.procursus_strapped` and `.installed_dopamine`. Shell, dpkg, apt and uicache are found.
14. Packages, Repositories, Tweaks/Safe Mode and Storage show plausible values (compare with Zebra). Share the report and attach it to the test record.
15. Environment and Tests → **Run Shell Test**: *Verified working*.

## D. Local terminal
16. Open a Local Unleashed session. A prompt appears for `mobile`. Run `id` (uid=501, not 0), `echo $SHELL`, `pwd`, `ls /var/jb`.
17. Interrupt: `sleep 30`, then Ctrl-C on the key row. The prompt must return at once.
18. Job control:
    - `sleep 100 &`, then `jobs` lists it, then `fg`, then Ctrl-Z stops it;
    - `bg` resumes it, then `kill %1`.
19. Interactive programs (if installed):
    - `vi /var/mobile/hcg-test.txt`: type text, `:wq`, then `cat` the file;
    - `top`, or `htop` if installed: quit with `q`;
    - `less /var/jb/etc/profile`.
20. Resize: rotate the device while `top` or `vi` runs. The program redraws to the new size.
21. ANSI: `ls --color=auto /var/jb/usr/bin | head`, or `printf '\033[31mred\033[0m\n'`.
22. Session history: up arrow recalls earlier commands. Closing the session ends the shell: `ps aux | grep -c "[z]sh"` in a new session.
23. Background:
    - put the app in the background for 1 minute while `sleep 120` runs, then return; the session is still there;
    - with `ping -c 100 1.1.1.1` running, the output continued or resumed after returning. Note which.
24. Privilege:
    - type `sudo id`: the command guard asks for confirmation first, then `sudo` asks for its own password (the default is set by the jailbreak, often `alpine`; change it).
    - Nothing runs as root unless you type it.

## E. Package workflow (optional, low risk)
25. Unleashed Tools → Packages: the inventory count matches `dpkg -l | grep -c ^ii`.
26. Optional: install a harmless package such as `nano`. The approval shows the exact command; it runs visibly in a session. Then remove it.

## F. Upgrade
27. Install the same `.deb` again with `sudo dpkg -i`. It must be accepted, with the icon still present and the app's saved hosts and settings kept.
28. When a later candidate exists (e.g. `0.2.0~rc2`), install it over `0.2.0~rc1` the same way. The version updates and data is kept.

## G. Uninstall
29. Remove it in Zebra (or `sudo dpkg -r com.hakmicapitalgroup.hcgterminal.unleashed`). The `postrm` output shows `uicache -u` and the icon disappears.
30. `ls /var/jb/Applications | grep -i hcg` shows nothing. `dpkg -s com.hakmicapitalgroup.hcgterminal.unleashed` shows not installed.
31. The App Store *HCG Terminal* (if installed) still opens and works unchanged.
32. Run `dpkg --get-selections > /var/mobile/dpkg-selections-after.txt; diff /var/mobile/dpkg-selections-before.txt /var/mobile/dpkg-selections-after.txt`. There is no difference except packages you installed on purpose.

## H. Safe Mode and recovery
33. Reinstall. Reboot the device and re-jailbreak with Dopamine. The app opens; the shell test passes again.
34. Confirm the package causes no Safe Mode: SpringBoard stays normal after installs and removals in steps 8, 27 and 29. Jailbreak Diagnostics → *SpringBoard crashes (7 days)* shows none newer than the test start.
35. Recovery drill (optional): with Tweak Injection off in Dopamine, the app still opens and the shell test passes (the app does not depend on tweak injection).

## Result
- Every step in A–D, F and G passes → record the device test in HCG Repo (`[versions."0.2.0~rc1"]` with `status = "device-tested"` and a `device_tests` entry: device, iOS, jailbreak, date, result, evidence).
- Then request publication approval. Without approval nothing is published.
- If spawn fails in step 15 with *Permission denied*, the entitlement set is not enough for this jailbreak. Report it. A different set needs review in both HCG-Terminal and HCG Repo; it is not changed silently.
