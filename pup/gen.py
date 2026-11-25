"""Distil pup lines from a big local teacher (qwen3:8b in Ollama) into a training set for the
tiny in-app model. Output: data.jsonl rows {"x": "<goal>|<arg>", "y": "<line>"}."""
import json, random, re, urllib.request, concurrent.futures as cf, sys

random.seed(7)
OWNER = "{owner}"  # the app swaps in each user's first name
PERSONA = (f"You write lines for Bruno, a small black-and-white dalmatian puppy living in {OWNER}'s MacBook notch. "
           "Warm, playful, a bit cheeky, loyal. Each line under 12 words, simple words, at most one emoji "
           "from this set only: 🐾 ☀️ 🎶 💛 🦴 🥺 🎾 🌙. No hashtags, no quotes, never mention AI.")
SONGS = ["Tum Hi Ho by Arijit Singh", "Kesariya by Arijit Singh", "Apna Bana Le by Arijit Singh", "Kun Faya Kun by A.R. Rahman",
         "Chaiyya Chaiyya by Sukhwinder Singh", "Pasoori by Ali Sethi", "Kahani Suno by Kaifi Khalil", "Raataan Lambiyan by Jubin Nautiyal",
         "Ilahi by Arijit Singh", "Agar Tum Saath Ho by Alka Yagnik", "Jhoome Jo Pathaan by Arijit Singh", "Maan Meri Jaan by King",
         "Excuses by AP Dhillon", "Brown Munde by AP Dhillon", "Husn by Anuv Jain", "Baarishein by Anuv Jain", "Tujhe Kitna Chahne Lage by Arijit Singh",
         "Kal Ho Naa Ho by Sonu Nigam", "Shape of You by Ed Sheeran", "Perfect by Ed Sheeran", "Blinding Lights by The Weeknd",
         "Levitating by Dua Lipa", "Believer by Imagine Dragons", "Yellow by Coldplay", "Viva La Vida by Coldplay", "Bohemian Rhapsody by Queen",
         "Let It Be by The Beatles", "Lose Yourself by Eminem", "Bad Guy by Billie Eilish", "Flowers by Miley Cyrus", "Anti-Hero by Taylor Swift",
         "Starboy by The Weeknd", "Despacito by Luis Fonsi", "Lofi beats to study to", "30 minutes of Bollywood Bangers", "Night Changes by One Direction",
         "Stay by Justin Bieber", "Heat Waves by Glass Animals", "Calm Down by Rema", "Satranga by Arijit Singh"]
MEETINGS = ["Weekly sync", "Budget review", "1:1 with manager", "Client call", "Design review", "Board prep", "Team standup",
            "Research huddle", "Data review", "Interview panel", "Townhall", "Project kickoff", "Vendor call", "Strategy session", "Lunch meeting"]
CHATS = ["who are you?", "what's your name?", "are you hungry?", "do you love me?", "good boy!", "I'm tired", "I'm sad today",
         "I'm so stressed", "good night", "good morning", "tell me a joke", "are you a good dog?", "let's play", "sit!", "roll over!",
         "I'm going out for a bit", "I'm back", "what are you doing?", "I finished my work!", "should I take a break?", "I love you",
         "what's your favourite food?", "do you like music?", "are you bored?", "I have a deadline", "wish me luck", "thank you",
         "I'm hungry too", "it's raining", "I got a promotion!", "I can't focus", "how are you?", "where do you live?", "can you guard my mac?",
         "who peeked at my screen?", "shake hands!", "speak!", "I'm leaving for the day", "happy birthday to me", "you're cute"]

def jobs():
    J = []
    for h in [1, 2, 3, 4]: J.append(("stretch", str(h), f"{OWNER} has worked {h} hours without a break.", "get him to stand up and stretch"))
    for part, sit in [("morning", f"Morning. {OWNER} just opened the laptop."), ("afternoon", f"{OWNER} is back after lunch."),
                      ("back", f"{OWNER} came back after an hour away."), ("monday", f"Monday morning, {OWNER} opened the laptop.")]:
        J.append(("greet", part, sit, "greet him"))
    for m in MEETINGS:
        mins = random.choice(["10", "5", "1"])
        J.append(("meeting", f"{m}|{mins}", f"Meeting in {mins} minutes: {m}.", "remind him, mention the meeting name"))
    for s in SONGS: J.append(("music", s, f"Music playing: {s}. You are dancing.", "vibe with him, mention the song"))
    J += [("hungry", "", "You are hungry, your bowl is empty.", "ask for food"),
          ("hungry", "lunch", "Lunch time and you are hungry.", "ask for lunch together"),
          ("hungry", "dinner", "Evening and you are hungry.", "ask for dinner"),
          ("fed", "", f"{OWNER} just fed you.", "thank him"),
          ("play", "", "You want to play fetch.", "invite him to play"),
          ("play", "bored", "You are bored.", "invite him to play"),
          ("played", "", f"{OWNER} threw the ball for you.", "react excitedly"),
          ("petted", "", f"{OWNER} petted you.", "react happily"),
          ("petted", "ears", f"{OWNER} scratched behind your ears.", "react happily"),
          ("home", "", "Evening, workday is over.", "tell him to go home"),
          ("home", "late", "It's 8pm and he is still at the office.", "tell him to go home"),
          ("late", "", "Late night, he is still working.", "sleepy nudge to rest"),
          ("late", "2am", "2am and he is still awake.", "insist he sleeps"),
          ("peek", "", "Someone looked at his screen while he was away.", "tell him, mention the eye tab"),
          ("peek", "touched", "Someone touched his Mac while he was away.", "tell him, sound protective"),
          ("guard", "", "He armed the guard and is leaving.", "promise to guard the Mac"),
          ("welcome", "", "He came back and you unlocked the guard for him.", "welcome him back"),
          ("done", "", "His long-running job just finished.", "celebrate"),
          ("battery", "low", "Laptop battery is at 15 percent.", "tell him to plug in"),
          ("battery", "charging", "He plugged in the charger.", "say thanks, you feel energised"),
          ("sleepy", "", "You are sleepy and lying down.", "say you'll nap"),
          ("wake", "", "You just woke up from a nap.", "stretch and say hi")]
    for q in CHATS: J.append(("chat", q, f"{OWNER} says to you: {q}", "reply as Bruno"))
    return J

def ask(job, n=16):
    key, arg, sit, goal = job
    prompt = (f"{PERSONA}\n\nSituation: {sit}\nGoal: {goal}\n\nWrite {n} different lines Bruno could say. "
              f"Return only a JSON array of {n} strings.")
    body = json.dumps({"model": "teacher", "temperature": 0.95, "top_p": 0.95, "max_tokens": 700,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request("http://127.0.0.1:1234/v1/chat/completions", body, {"Content-Type": "application/json"})
    try:
        out = json.loads(urllib.request.urlopen(req, timeout=300).read())["choices"][0]["message"]["content"]
    except Exception as e:
        print("fail", key, arg, e, file=sys.stderr); return []
    try:
        data = json.loads(out[out.index("["): out.rindex("]") + 1])
    except Exception:
        data = re.findall(r'"([^"]{6,90})"', out)  # salvage quoted strings
    rows = []
    for line in data:
        if not isinstance(line, str): continue
        line = re.sub(r"\s+", " ", line).strip().strip('"')
        if 6 <= len(line) <= 90 and " AI" not in line:
            rows.append({"x": f"{key}|{arg}" if arg else key, "y": line})
    return rows

if __name__ == "__main__":
    J = jobs()  # 16 lines each -> ~2000 lines
    print(len(J), "situations", flush=True)
    with open("data.jsonl", "w") as f, cf.ThreadPoolExecutor(4) as ex:
        futs = [ex.submit(ask, j) for j in J]
        for done, fu in enumerate(cf.as_completed(futs), 1):
            for r in fu.result(): f.write(json.dumps(r, ensure_ascii=False) + "\n")
            f.flush()
            if done % 10 == 0: print(done, "/", len(J), flush=True)
    print("done", flush=True)
