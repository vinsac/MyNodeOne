# 🌱 Absolute Beginner's Guide to MyNodeOne

**Never used Linux or command line before?** This guide is for you!

---

## 🎯 What You'll Learn

This guide teaches you the **absolute basics** you need to install MyNodeOne:
- How to open a terminal
- How to copy and paste commands
- What those commands actually do
- What to expect when you run them

**Time needed:** 10 minutes to read, then you're ready!

---

## 📺 Step 0: Opening the Terminal

The terminal is where you type commands. Here's how to open it:

### On Ubuntu Desktop:

**Option 1: Keyboard Shortcut** (Easiest)
1. Press `Ctrl` + `Alt` + `T` together
2. A black window will open - this is the terminal!

**Option 2: Using the Menu**
1. Click "Activities" in the top-left corner
2. Type "terminal" in the search box
3. Click on "Terminal" when it appears

**Option 3: Right-Click Menu**
1. Right-click on your desktop
2. Select "Open in Terminal" (if available)

**What you'll see:**
```
username@computername:~$
```
This is called the "command prompt" - it's waiting for you to type something!

---

## 📋 Copying and Pasting Commands

### In the Terminal:

**❌ DON'T use Ctrl+C and Ctrl+V** (these mean something different in terminal!)

**✅ DO use these instead:**

**To Copy:**
- Highlight text with your mouse
- Press `Ctrl` + `Shift` + `C`
- OR right-click and select "Copy"

**To Paste:**
- Press `Ctrl` + `Shift` + `V`
- OR right-click and select "Paste"
- OR middle-click your mouse (on some systems)

**Pro Tip:** You can also right-click in the terminal for a menu!

---

## 🔐 Understanding `sudo` and Passwords

### What is `sudo`?

**Simple explanation:** `sudo` means "run this command as administrator"

**Why needed:** Some commands need permission to modify system files (like installing software).

### What Happens When You Type `sudo`?

1. You type: `sudo apt update`
2. Press Enter
3. Terminal asks: `[sudo] password for username:`
4. **Type your password** (the one you use to log into Ubuntu)
5. **IMPORTANT:** You won't see anything as you type the password - this is normal!
6. Press Enter

**It's like this:**
```bash
$ sudo apt update
[sudo] password for john: ▋         ← cursor, but no visible text!
```

**Why can't I see my password?**
- It's a security feature!
- The computer IS receiving your typing
- Just type carefully and press Enter

---

## 📚 Understanding Basic Commands

Let's break down the commands you'll use:

### 1. `sudo apt update`

**What it does:** Updates the list of available software  
**Like:** Refreshing the app store catalog  
**Time:** 5-30 seconds  
**You'll see:** Lots of text scrolling - this is normal!

```bash
sudo apt update
# Output:
# Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease
# Get:2 http://archive.ubuntu.com/ubuntu jammy-updates InRelease
# Reading package lists... Done
```

### 2. `sudo apt install -y git`

**What it does:** Installs the git program  
**The `-y` means:** Automatically say "yes" to installation prompts  
**Like:** Clicking "Install" in an app store  
**Time:** 30 seconds - 2 minutes

```bash
sudo apt install -y git
# Output:
# Reading package lists... Done
# Building dependency tree... Done
# Unpacking git (...)
# Setting up git (...)
```

### 3. `git clone https://github.com/vinsac/MyNodeOne.git`

**What it does:** Downloads MyNodeOne code to your computer  
**Like:** Downloading a ZIP file and extracting it  
**Time:** 5-30 seconds  
**Creates:** A folder called "MyNodeOne" in your current location

```bash
git clone https://github.com/vinsac/MyNodeOne.git
# Output:
# Cloning into 'MyNodeOne'...
# remote: Counting objects: 100% (123/123), done.
# Receiving objects: 100% (123/123), done.
```

### 4. `cd MyNodeOne`

**What it does:** Changes directory (goes into the MyNodeOne folder)  
**Like:** Double-clicking a folder to open it  
**Time:** Instant  
**You'll see:** Your prompt changes to show you're in MyNodeOne

```bash
cd MyNodeOne
# Before: username@computername:~$
# After:  username@computername:~/MyNodeOne$
```

### 5. `sudo ./scripts/mynodeone`

**What it does:** Runs the main MyNodeOne installer  
**Time:** 30-45 minutes  
**Interactive:** Will ask you questions - read and answer them

```bash
sudo ./scripts/mynodeone
# This starts the installation wizard
# You'll see a welcome screen and prompts
```

---

## 🎨 What to Expect - Visual Guide

### Normal Output Looks Like This:

```bash
$ sudo apt update
[sudo] password for john: 
Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease
Get:2 http://archive.ubuntu.com/ubuntu jammy-updates InRelease [119 kB]
Fetched 119 kB in 2s (59.5 kB/s)
Reading package lists... Done
Building dependency tree... Done
```

**✅ This is GOOD!** Lots of text, "Done" at the end.

### Error Looks Like This:

```bash
$ git clone https://wrong-url.git
fatal: unable to access 'https://wrong-url.git/': Could not resolve host: wrong-url.git
```

**❌ This is an ERROR!** Words like "fatal", "error", "failed".

**What to do:**
1. Read the error message (it often tells you what's wrong)
2. Check if you typed the command correctly
3. Check your internet connection
4. Ask ChatGPT or Gemini: "What does this error mean: [paste error]"

---

## 🔄 Common Scenarios

### Scenario 1: Command Seems Stuck

**What you see:**
```bash
$ sudo apt install git
[sudo] password for john: ▋
```

**What's happening:** It's waiting for your password!  
**What to do:** Type your password (you won't see it) and press Enter

---

### Scenario 2: Need to Cancel a Command

**How to stop a running command:**
- Press `Ctrl` + `C` together
- This sends a "stop" signal to the command

**Example:**
```bash
$ ping google.com
(keeps running forever)
^C                    ← You pressed Ctrl+C
$                     ← Command stopped, you're back at prompt
```

---

### Scenario 3: Made a Typo

**What you see:**
```bash
$ gi clone https://github.com/vinsac/MyNodeOne.git
gi: command not found
```

**What happened:** Typed "gi" instead of "git"  
**What to do:**
1. Press ↑ (up arrow) to bring back the last command
2. Use ← → (left/right arrows) to move cursor
3. Fix the typo
4. Press Enter

---

## 🧭 Navigation Basics

### Where Am I?

Type: `pwd` (Print Working Directory)
```bash
$ pwd
/home/john
```

### What's Here?

Type: `ls` (List contents)
```bash
$ ls
Desktop  Documents  Downloads  MyNodeOne  Pictures
```

### Go to Home Folder

Type: `cd ~` or just `cd`
```bash
$ cd ~
$ pwd
/home/john
```

---

## ⏱️ Time Expectations

Here's how long each step typically takes:

| Step | Time | What Happens |
|------|------|--------------|
| **apt update** | 5-30 seconds | Text scrolls, then "Done" |
| **apt install git** | 30 sec - 2 min | Downloads and installs git |
| **git clone** | 5-30 seconds | Downloads MyNodeOne code |
| **cd MyNodeOne** | Instant | Changes to MyNodeOne folder |
| **./scripts/mynodeone** | 30-45 minutes | Interactive installation |

**Total time:** Plan for 1 hour start to finish

---

## ❓ Common Questions

### Q: Can I close the terminal window?

**During installation:** ❌ NO! Wait until it's finished.  
**After commands complete:** ✅ Yes, you can close it.

### Q: What if I make a mistake?

**Good news:** Most commands can be undone or re-run!  
**The installer:** Has safety checks and asks for confirmation.

### Q: Do I need to be online?

**Yes!** You need internet to:
- Download MyNodeOne
- Install software packages
- Set up Tailscale

### Q: What if something goes wrong?

**Don't panic!** Here's what to do:
1. Read the error message
2. Check [docs/troubleshooting.md](docs/troubleshooting.md)
3. Ask ChatGPT: "I got this error with MyNodeOne: [paste error]"
4. Check [FAQ.md](FAQ.md)
5. Open a GitHub Issue with the error message

---

## 🎓 You're Ready!

You now know:
- ✅ How to open terminal
- ✅ How to copy/paste commands
- ✅ What `sudo` means
- ✅ What to expect when running commands
- ✅ How to navigate and fix mistakes

**Next step:** Go to [QUICKSTART.md](QUICKSTART.md) and start installing!

---

## 🆘 Getting Help

**If you're stuck:**
- Check [GLOSSARY.md](GLOSSARY.md) for technical terms
- Ask ChatGPT, Gemini, or Claude
- Read [FAQ.md](FAQ.md)
- Open a GitHub Issue (we're friendly!)

**Remember:** Everyone was a beginner once. Take your time, read carefully, and don't be afraid to ask for help!

---

## 🎯 Quick Reference Card

**Copy this for easy reference:**

```
Open Terminal:        Ctrl + Alt + T
Copy in Terminal:     Ctrl + Shift + C
Paste in Terminal:    Ctrl + Shift + V
Stop Command:         Ctrl + C
Previous Command:     ↑ (Up Arrow)
Where Am I:           pwd
List Files:           ls
Go to Home:           cd ~
Go into Folder:       cd foldername
Go up One Level:      cd ..
```

---

**Ready to start?** Go to → [QUICKSTART.md](QUICKSTART.md)

**Need simpler explanations?** See → [GLOSSARY.md](GLOSSARY.md)

**Questions?** Check → [FAQ.md](FAQ.md)
