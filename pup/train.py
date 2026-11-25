"""Train Bruno's tiny brain: a ~10M-parameter character-level GPT, conditioned on
"<goal>|<arg>" and trained to write the pup's line. Exports pup.bin + pup.json for the
Swift engine in Island (TinyGPT.swift), which re-implements exactly this forward pass.

  .venv/bin/python train.py            # train + export
  .venv/bin/python train.py --sample   # sample from the exported checkpoint
"""
import json, math, random, struct, sys, time
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np

random.seed(0); np.random.seed(0); mx.random.seed(0)

# ---------- config (~10M params)
N_LAYER, N_EMBD, N_HEAD, BLOCK = 8, 320, 8, 160
STEPS, BATCH, LR, DROPOUT = 7000, 64, 1.2e-3, 0.05
RESUME = "--resume" in sys.argv
SEP, END = "\t", "\n"

# ---------- data
rows = [json.loads(l) for l in open("data.jsonl", encoding="utf-8")]
SONG_TITLES = ["Tum Hi Ho", "Kesariya", "Apna Bana Le", "Kun Faya Kun", "Chaiyya Chaiyya", "Pasoori", "Kahani Suno",
               "Raataan Lambiyan", "Ilahi", "Agar Tum Saath Ho", "Jhoome Jo Pathaan", "Maan Meri Jaan", "Excuses",
               "Brown Munde", "Husn", "Baarishein", "Tujhe Kitna Chahne Lage", "Kal Ho Naa Ho", "Shape of You", "Perfect",
               "Blinding Lights", "Levitating", "Believer", "Yellow", "Viva La Vida", "Bohemian Rhapsody", "Let It Be",
               "Lose Yourself", "Bad Guy", "Flowers", "Anti-Hero", "Starboy", "Despacito", "Night Changes", "Stay",
               "Heat Waves", "Calm Down", "Satranga"]
EXTRA_TITLES = ["Sunflower", "Dil Diyan Gallan", "Channa Mereya", "Hotel California", "Numb", "Lag Ja Gale", "Senorita",
                "Gulabi Aankhen", "Phir Se Ud Chala", "Faded", "Counting Stars", "Tera Ban Jaunga", "Kabira", "Closer",
                "Shayad", "Zinda", "Daylight", "Riptide", "Kho Gaye Hum Kahan", "Iktara", "Golden Hour", "Softly",
                "Monsoon Mix", "Focus Beats", "Pehle Bhi Main", "Ranjha", "As It Was", "Paint The Town Red", "Tere Vaaste"]
MEETING_EXTRA = ["Sprint planning", "Quarterly review", "Investor call", "HR check-in", "Policy roundtable", "Ops sync",
                 "Product demo", "Field update", "Grant review", "Partner meeting", "Weekly catch-up", "Hiring sync"]


def augment(rows):
    """Teach copying: swap the song / meeting name in lines that quote it for unseen names."""
    out = list(rows)
    for r in rows:
        key, _, arg = r["x"].partition("|")
        if key == "music":
            title = arg.split(" by ")[0]
            if title.lower() in r["y"].lower():
                for t in random.sample(SONG_TITLES + EXTRA_TITLES, 4):
                    i = r["y"].lower().index(title.lower())
                    y = r["y"][:i] + t + r["y"][i + len(title):]
                    out.append({"x": f"music|{t}", "y": y})
            out.append({"x": f"music|{title}", "y": r["y"]})
        elif key == "meeting":
            name, _, mins = arg.partition("|")
            if name.lower() in r["y"].lower():
                for m in random.sample(MEETING_EXTRA, 3):
                    i = r["y"].lower().index(name.lower())
                    out.append({"x": f"meeting|{m}|{mins}", "y": r["y"][:i] + m + r["y"][i + len(name):]})
    return out


def clean_x(x):  # music arg: title only (the app sends just the title)
    key, _, arg = x.partition("|")
    if key == "music": return f"music|{arg.split(' by ')[0]}"
    return x


data = [{"x": clean_x(r["x"]), "y": r["y"]} for r in augment(rows)]
data = [d for d in data if len(d["x"]) + len(d["y"]) + 2 <= BLOCK]
random.shuffle(data)
chars = sorted(set("".join(d["x"] + SEP + d["y"] + END for d in data)) | set(" abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?'-:|"))
PAD = len(chars)  # extra index used only for padding (never predicted)
stoi = {c: i for i, c in enumerate(chars)}
V = len(chars) + 1
n_val = max(60, len(data) // 20)
val, train = data[:n_val], data[n_val:]
print(f"{len(rows)} teacher lines -> {len(data)} with augmentation; vocab {V}")


def encode(d):
    s = d["x"] + SEP + d["y"] + END
    ids = [stoi.get(c, stoi[" "]) for c in s]
    start = len(d["x"]) + 1  # loss only on the line (after the tab)
    x = ids[:-1] + [PAD] * (BLOCK - len(ids) + 1)
    y = ids[1:] + [PAD] * (BLOCK - len(ids) + 1)
    m = [0] * (start - 1) + [1] * (len(ids) - start) + [0] * (BLOCK - len(ids) + 1)
    return x[:BLOCK], y[:BLOCK], m[:BLOCK]


def batch(src, n):
    picks = [random.choice(src) for _ in range(n)]
    b = [encode(d) for d in picks]
    L = max(len(d["x"]) + len(d["y"]) + 2 for d in picks)
    L = min(BLOCK, (L + 15) // 16 * 16)  # pad to the longest in the batch, not the full block
    return tuple(mx.array([r[i][:L] for r in b]) for i in range(3))


# ---------- model (pre-LN GPT, tied embeddings, tanh-GELU; mirrored in Swift)
def gelu(x): return 0.5 * x * (1 + mx.tanh(math.sqrt(2 / math.pi) * (x + 0.044715 * x ** 3)))


class Block(nn.Module):
    def __init__(self):
        super().__init__()
        self.ln1, self.ln2 = nn.LayerNorm(N_EMBD), nn.LayerNorm(N_EMBD)
        self.qkv = nn.Linear(N_EMBD, 3 * N_EMBD)
        self.proj = nn.Linear(N_EMBD, N_EMBD)
        self.fc = nn.Linear(N_EMBD, 4 * N_EMBD)
        self.out = nn.Linear(4 * N_EMBD, N_EMBD)
        self.drop = nn.Dropout(DROPOUT)

    def __call__(self, x, mask):
        B, T, C = x.shape
        q, k, v = mx.split(self.qkv(self.ln1(x)), 3, axis=-1)
        hd = C // N_HEAD
        q, k, v = (t.reshape(B, T, N_HEAD, hd).transpose(0, 2, 1, 3) for t in (q, k, v))
        att = (q @ k.transpose(0, 1, 3, 2)) / math.sqrt(hd) + mask
        y = (mx.softmax(att, axis=-1) @ v).transpose(0, 2, 1, 3).reshape(B, T, C)
        x = x + self.drop(self.proj(y))
        return x + self.drop(self.out(gelu(self.fc(self.ln2(x)))))


class GPT(nn.Module):
    def __init__(self):
        super().__init__()
        self.tok = nn.Embedding(V, N_EMBD)
        self.pos = nn.Embedding(BLOCK, N_EMBD)
        self.blocks = [Block() for _ in range(N_LAYER)]
        self.ln_f = nn.LayerNorm(N_EMBD)

    def __call__(self, idx):
        T = idx.shape[1]
        x = self.tok(idx) + self.pos(mx.arange(T))
        mask = nn.MultiHeadAttention.create_additive_causal_mask(T).astype(x.dtype)
        for b in self.blocks: x = b(x, mask)
        return self.ln_f(x) @ self.tok.weight.T  # tied output head


def loss_fn(model, x, y, m):
    logits = model(x)
    ce = nn.losses.cross_entropy(logits, y, reduction="none")
    return (ce * m).sum() / m.sum()


def export(model, path="pup"):
    flat = dict(nn.utils.tree_flatten(model.parameters()))
    order = ["tok.weight", "pos.weight"]
    for i in range(N_LAYER):
        for n in ["ln1.weight", "ln1.bias", "qkv.weight", "qkv.bias", "proj.weight", "proj.bias",
                  "ln2.weight", "ln2.bias", "fc.weight", "fc.bias", "out.weight", "out.bias"]:
            order.append(f"blocks.{i}.{n}")
    order += ["ln_f.weight", "ln_f.bias"]
    with open(f"{path}.bin", "wb") as f:
        for n in order: f.write(np.array(flat[n], dtype=np.float32).tobytes())
    meta = {"n_layer": N_LAYER, "n_embd": N_EMBD, "n_head": N_HEAD, "block": BLOCK, "vocab": chars,
            "pad": PAD, "order": order, "shapes": {n: list(flat[n].shape) for n in order}}
    json.dump(meta, open(f"{path}.json", "w"), ensure_ascii=False)
    total = sum(int(np.prod(flat[n].shape)) for n in order)
    print(f"exported {total/1e6:.2f}M params -> {path}.bin ({total*4/1e6:.1f} MB)")


def sample(model, x, temp=0.8, topk=20):
    ids = [stoi.get(c, stoi[" "]) for c in x + SEP]
    out = ""
    for _ in range(100):
        logits = model(mx.array([ids[-BLOCK:]]))[0, -1]
        logits = np.array(logits[:PAD]) / temp
        top = np.argsort(logits)[-topk:]
        p = np.exp(logits[top] - logits[top].max()); p /= p.sum()
        nxt = int(np.random.choice(top, p=p))
        if chars[nxt] == END: break
        out += chars[nxt]; ids.append(nxt)
    return out


def greedy_check():
    """Same prompts as tools/gptcheck: Swift output must match exactly."""
    model = GPT(); model.load_weights("pup.safetensors"); model.eval()
    for x in ["greet|morning", "music|Tum Hi Ho", "hungry", "chat|do you love me?"]:
        print(f"GREEDY {x} -> {sample(model, x, temp=1e-6, topk=1)}")


if __name__ == "__main__" and "--check" in sys.argv:
    greedy_check(); sys.exit()

if __name__ == "__main__":
    model = GPT()
    if RESUME:
        model.load_weights("pup.safetensors")
        print("resuming from pup.safetensors")
    mx.eval(model.parameters())
    n = sum(v.size for _, v in nn.utils.tree_flatten(model.parameters()))
    print(f"model {n/1e6:.2f}M params")
    warm = optim.linear_schedule(LR * 0.1, LR, 300)
    sched = optim.join_schedules([warm, optim.cosine_decay(LR, STEPS - 300, LR * 0.03)], [300])
    opt = optim.AdamW(learning_rate=sched, weight_decay=0.05)
    step_fn = nn.value_and_grad(model, loss_fn)
    best, t0 = 9e9, time.time()
    for it in range(1, STEPS + 1):
        model.train()
        loss, grads = step_fn(model, *batch(train, BATCH))
        opt.update(model, grads)
        mx.eval(model.parameters(), opt.state)
        if it % 500 == 0 or it == STEPS:
            model.eval()
            vl = np.mean([loss_fn(model, *batch(val, 64)).item() for _ in range(4)])
            print(f"step {it} train {loss.item():.3f} val {vl:.3f} ({time.time()-t0:.0f}s)", flush=True)
            if vl < best:
                best = vl
                model.save_weights("pup.safetensors")
    model.load_weights("pup.safetensors")
    model.eval()
    export(model)
    for x in ["greet|morning", "stretch|2", "music|Tum Hi Ho", "music|Golden Hour", "meeting|Sprint planning|10",
              "hungry", "fed", "play", "petted", "home", "late", "peek", "chat|do you love me?", "chat|I'm so stressed"]:
        print(f"{x:28s} -> {sample(model, x)}")

