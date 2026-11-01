#!/usr/bin/env python3
"""Web search for llama-server: a small MCP tool server (stdio, no dependencies).

llama-server starts this script (see /etc/pi-llm/mcp.json) and offers its two
tools to the model as `web_search` and `web_fetch`:

  search  find pages: titles, URLs and short snippets
  fetch   read one page as plain text, shortened to keep the Pi fast

Settings come from the environment, normally /etc/pi-llm/web-search.env:

  WEB_SEARCH_ENGINE    tavily | brave | searxng
  TAVILY_API_KEY       for tavily  (https://app.tavily.com)
  BRAVE_API_KEY        for brave   (https://api-dashboard.search.brave.com)
  SEARXNG_URL          for searxng, your own instance, e.g. http://127.0.0.1:8888
  WEB_SEARCH_RESULTS   results per search (default 5)
  WEB_FETCH_MAX_CHARS  page text limit (default 6000, about 1,500 tokens)

Try it without the model:

  python3 web-search-mcp.py --search "raspberry pi 5 active cooler"
  python3 web-search-mcp.py --fetch https://example.com

Protocol: one JSON-RPC message per line on stdin/stdout (MCP stdio transport).
Logs go to stderr.
"""

import codecs
import datetime
import html
import http.client
import ipaddress
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

VERSION = "1.0"
USER_AGENT = (f"Mozilla/5.0 (compatible; pi-llm-web-search/{VERSION}; "
              "+https://github.com/nicolaszimmer/pi-edge-ai)")
TIMEOUT = 20                       # seconds per network operation of a search
FETCH_TIMEOUT = 10                 # seconds per network operation of a page fetch
FETCH_DEADLINE = 25                # seconds for a whole page fetch (llama-server allows 60)
MAX_DOWNLOAD = 3 * 1024 * 1024     # bytes read from a page at most
SNIPPET_CHARS = 400


def env_int(name, default, low, high):
    try:
        return max(low, min(high, int(os.environ.get(name, default))))
    except ValueError:
        return default


ENGINE = os.environ.get("WEB_SEARCH_ENGINE", "").strip().lower()
RESULTS = env_int("WEB_SEARCH_RESULTS", 5, 1, 10)
FETCH_MAX_CHARS = env_int("WEB_FETCH_MAX_CHARS", 6000, 500, 100000)


class ToolError(Exception):
    """An error the model should see as the tool result."""


def log(message):
    print(f"web-search: {message}", file=sys.stderr, flush=True)


def shorten(text, limit):
    text = re.sub(r"\s+", " ", text or "").strip()
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + " …"


def strip_tags(text):
    return html.unescape(re.sub(r"<[^>]+>", "", text or ""))


# --------------------------------------------------------------------------
# Search
# --------------------------------------------------------------------------

def http_json(url, *, body=None, headers=None, engine=""):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        **({"Content-Type": "application/json"} if data else {}),
        **(headers or {}),
    })
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        detail = shorten(e.read(500).decode("utf-8", "replace"), 200)
        if e.code in (401, 403) and engine != "searxng":
            raise ToolError(f"{engine} rejected the API key (HTTP {e.code}). "
                            "Check it in /etc/pi-llm/web-search.env.") from e
        if e.code == 429:
            raise ToolError(f"{engine}: too many requests or monthly quota used up (HTTP 429).") from e
        raise ToolError(f"{engine} returned HTTP {e.code}: {detail}") from e
    except (urllib.error.URLError, socket.timeout, TimeoutError) as e:
        raise ToolError(f"could not reach {engine}: {getattr(e, 'reason', e)}") from e
    except ValueError as e:
        raise ToolError(f"{engine} did not return JSON") from e


def need(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise ToolError(f"web search is not set up: {name} is empty. "
                        "Run ./web-search.sh on (in pi-edge-ai/pi) on the Pi.")
    return value


def search_tavily(query, count):
    key = need("TAVILY_API_KEY")
    data = http_json("https://api.tavily.com/search", engine="tavily",
                     headers={"Authorization": f"Bearer {key}"},
                     body={"query": query, "max_results": count, "search_depth": "basic"})
    return [(r.get("title"), r.get("url"), r.get("content"), r.get("published_date"))
            for r in data.get("results", [])]


def search_brave(query, count):
    key = need("BRAVE_API_KEY")
    url = "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode(
        {"q": query, "count": count})
    data = http_json(url, engine="brave", headers={"X-Subscription-Token": key})
    return [(strip_tags(r.get("title")), r.get("url"), strip_tags(r.get("description")), r.get("age"))
            for r in (data.get("web") or {}).get("results", [])]


def search_searxng(query, count):
    base = need("SEARXNG_URL").rstrip("/")
    url = base + "/search?" + urllib.parse.urlencode({"q": query, "format": "json"})
    try:
        data = http_json(url, engine="searxng")
    except ToolError as e:
        if "HTTP 403" in str(e):
            raise ToolError("SearXNG refused the JSON API (HTTP 403). Add `json` under "
                            "search: formats: in its settings.yml and restart it.") from e
        raise
    return [(r.get("title"), r.get("url"), r.get("content"), r.get("publishedDate"))
            for r in data.get("results", [])][:count]


ENGINES = {"tavily": search_tavily, "brave": search_brave, "searxng": search_searxng}


def web_search(args):
    query = str(args.get("query") or "").strip()
    if not query:
        raise ToolError("query is empty")
    if ENGINE not in ENGINES:
        raise ToolError("web search is not set up: WEB_SEARCH_ENGINE must be tavily, brave or "
                        "searxng. Run ./web-search.sh on (in pi-edge-ai/pi) on the Pi.")
    results = ENGINES[ENGINE](query, RESULTS)
    if not results:
        return f'No web results for "{query}". Try other words.'

    today = datetime.date.today().isoformat()
    lines = [f'Web results for "{query}" (searched {today}):']
    for i, (title, url, snippet, date) in enumerate(results, 1):
        lines.append("")
        lines.append(f"{i}. {shorten(title, 150) or url}")
        lines.append(f"   {url}")
        text = shorten(snippet, SNIPPET_CHARS)
        if date:
            text = f"({shorten(str(date), 30)}) {text}"
        if text:
            lines.append(f"   {text}")
    lines.append("")
    lines.append("Use web_fetch with a URL to read a page in full.")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Fetch
# --------------------------------------------------------------------------

def public_addresses(host, port):
    """Resolve host and return its addresses, or raise if any of them is not public."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except (socket.gaierror, UnicodeError, ValueError) as e:
        raise ToolError(f"could not resolve {host}") from e
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%")[0])
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        if not ip.is_global:
            raise ToolError(f"{host} is a local or private address; only public web pages "
                            "can be fetched")
    return infos


def check_public_url(url):
    """Only public http(s) pages: keep the model away from the router admin page & co.
    This early check gives a clear error; the connection itself is checked again below."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ToolError("only http:// and https:// URLs can be fetched")
    host = parts.hostname
    if not host:
        raise ToolError(f"not a valid URL: {url}")
    try:
        port = parts.port or (443 if parts.scheme == "https" else 80)
    except ValueError as e:
        raise ToolError(f"not a valid URL: {url}") from e
    public_addresses(host, port)


def connect_public(host, port, timeout):
    """Connect only to an address that passed the check. Checking and connecting use the
    same DNS answer, so a name that changes its answer in between (DNS rebinding) can't
    sneak a local address past the check."""
    error = None
    for family, kind, proto, _, address in public_addresses(host, port):
        sock = socket.socket(family, kind, proto)
        try:
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(timeout)
            sock.connect(address)
            return sock
        except OSError as e:
            sock.close()
            error = e
    raise error or OSError(f"could not connect to {host}")


class PublicHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = connect_public(self.host, self.port, self.timeout)


class PublicHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        if self._tunnel_host:  # through an HTTPS proxy, which resolves the name itself
            return super().connect()
        sock = connect_public(self.host, self.port, self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class PublicHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        if req.has_proxy():  # plain HTTP through a proxy: it connects, not us
            return super().http_open(req)
        return self.do_open(PublicHTTPConnection, req)


class PublicHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(PublicHTTPSConnection, req, context=self._context)


class CheckedRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class TextExtractor(HTMLParser):
    """HTML -> readable text. Drops scripts, menus, banners and footers; keeps headings and lists."""

    # always skipped, with everything inside
    SKIP = {"head", "script", "style", "noscript", "svg", "template", "iframe", "nav", "footer",
            "aside", "button", "select", "textarea", "dialog", "canvas"}
    # skipped when their class/id/role says "menu", "cookie banner" and the like
    # (only tags that always have an end tag, so the nesting can be tracked)
    MAYBE_SKIP = {"div", "section", "ul", "ol", "table", "header", "figure", "span", "sup", "form"}
    BOILERPLATE = {"nav", "navbar", "navigation", "menu", "menubar", "sidebar", "footer",
                   "dropdown", "cookie", "cookies", "consent", "gdpr", "banner", "breadcrumb",
                   "breadcrumbs", "share", "sharing", "social", "advert", "advertisement", "ad",
                   "ads", "promo", "popup", "modal", "newsletter", "subscribe", "related",
                   "comments", "toc", "editsection", "reference", "references", "noprint"}
    SKIP_ROLES = {"navigation", "banner", "contentinfo", "complementary", "search", "menu",
                  "menubar", "dialog", "alert"}
    # a <form> is only skipped when it looks like one of these. Some sites (ASP.NET
    # WebForms, portals) wrap the whole page in a single form.
    FORM_BOILERPLATE = {"search", "login", "signin", "signup", "register", "subscribe",
                        "newsletter", "comment", "comments", "contact"}
    BLOCK = {"p", "div", "section", "article", "main", "header", "ul", "ol", "table", "tr",
             "blockquote", "pre", "br", "hr", "dl", "dt", "dd", "figcaption", "td", "th"}
    HEADINGS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 4, "h6": 4}
    # elements without an end tag: never start a skipped region with one
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
            "source", "track", "wbr"}
    PRE_START, PRE_END = "\x02", "\x03"   # marks <pre> text, so tidy() keeps its indentation

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip_tag = None   # tag that started the skipped region
        self.skip_depth = 0    # its nesting depth
        self.main = 0
        self.pre = 0
        self.in_title = False
        self.title_done = False
        self.title = ""
        self.all = []
        self.main_text = []

    def is_boilerplate(self, tag, attrs):
        if tag in self.VOID:
            return False
        if tag in self.SKIP:
            return True
        attrs = dict(attrs)
        if "hidden" in attrs or attrs.get("aria-hidden") == "true":
            return True
        if attrs.get("role") in self.SKIP_ROLES:
            return tag in self.MAYBE_SKIP or tag in ("nav", "aside", "footer")
        if tag not in self.MAYBE_SKIP:
            return False
        names = f"{attrs.get('class') or ''} {attrs.get('id') or ''}".lower()
        words = self.BOILERPLATE | (self.FORM_BOILERPLATE if tag == "form" else set())
        return any(word in words for word in re.split(r"[\s_-]+", names))

    def emit(self, text):
        self.all.append(text)
        if self.main:
            self.main_text.append(text)

    def handle_starttag(self, tag, attrs):
        if tag == "title" and not self.title_done and self.skip_tag in (None, "head"):
            self.in_title = True  # the page title, not an <svg><title> icon label
        if tag == "body":  # also ends a <head> that was never closed
            self.skip_tag, self.skip_depth = None, 0
        if self.skip_tag:
            if tag == self.skip_tag:
                self.skip_depth += 1
            return
        if self.is_boilerplate(tag, attrs):
            self.skip_tag, self.skip_depth = tag, 1
            return
        if tag in ("main", "article"):
            self.main += 1
        if tag == "pre":
            self.pre += 1
            if self.pre == 1:
                self.emit(self.PRE_START)
        if tag in self.HEADINGS:
            self.emit("\n\n" + "#" * self.HEADINGS[tag] + " ")
        elif tag == "li":
            self.emit("\n- ")
        elif tag in self.BLOCK:
            self.emit("\n")

    def handle_endtag(self, tag):
        if tag == "title" and self.in_title:
            self.in_title, self.title_done = False, True
        if self.skip_tag:
            if tag == self.skip_tag:
                self.skip_depth -= 1
                if self.skip_depth == 0:
                    self.skip_tag = None
            return
        if tag in ("main", "article"):
            self.main = max(0, self.main - 1)
        if tag == "pre" and self.pre:
            self.pre -= 1
            if self.pre == 0:
                self.emit(self.PRE_END)
        if tag in self.HEADINGS or tag in self.BLOCK or tag == "li":
            self.emit("\n")

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self.skip_tag:
            return
        self.emit(data if self.pre else re.sub(r"\s+", " ", data))

    @classmethod
    def tidy(cls, parts):
        out, last = [], None
        # re.split with a group alternates: normal text, <pre> text, normal text, ...
        pattern = re.escape(cls.PRE_START) + "(.*?)" + re.escape(cls.PRE_END)
        for i, segment in enumerate(re.split(pattern, "".join(parts), flags=re.S)):
            segment = segment.replace(cls.PRE_START, "").replace(cls.PRE_END, "")
            if i % 2:  # preformatted (code): keep indentation and inner blank lines
                code = [line.rstrip() for line in segment.splitlines()]
                while code and not code[0]:
                    code.pop(0)
                while code and not code[-1]:
                    code.pop()
                if code:
                    out.append("```\n" + "\n".join(code) + "\n```")
                    last = None
                continue
            for line in segment.splitlines():
                line = re.sub(r" {2,}", " ", line).strip()
                if line and line != last:
                    out.append(line)
                last = line or last
        return "\n".join(out)

    def result(self):
        main = self.tidy(self.main_text)
        text = main if len(main) >= 400 else self.tidy(self.all)
        return shorten(self.title, 200), text


def guess_charset(raw, header_charset):
    for candidate in (header_charset,
                      (re.search(rb"""<meta[^>]+charset=["']?([\w-]+)""", raw[:4096], re.I)
                       or [None, None])[1]):
        if candidate:
            name = candidate.decode("ascii", "ignore") if isinstance(candidate, bytes) else candidate
            try:
                return codecs.lookup(name).name
            except LookupError:
                pass
    return "utf-8"


def download(url, deadline):
    """Fetch url, reading the body in chunks until MAX_DOWNLOAD or the deadline."""
    opener = urllib.request.build_opener(PublicHTTPHandler, PublicHTTPSHandler, CheckedRedirects)
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5",
    })
    try:
        with opener.open(request, timeout=FETCH_TIMEOUT) as response:
            chunks, size, cut_short = [], 0, False
            while size < MAX_DOWNLOAD:
                if time.monotonic() > deadline:
                    cut_short = True
                    break
                chunk = response.read1(min(65536, MAX_DOWNLOAD - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            return {"url": response.geturl(), "ctype": response.headers.get_content_type(),
                    "charset": response.headers.get_content_charset(),
                    "raw": b"".join(chunks), "cut_short": cut_short}
    except urllib.error.HTTPError as e:
        error = ToolError(f"the page returned HTTP {e.code} ({e.reason}); try another result")
    except (urllib.error.URLError, socket.timeout, TimeoutError, http.client.HTTPException) as e:
        error = ToolError(f"could not load the page: {getattr(e, 'reason', e)}")
    except Exception as e:  # incl. ToolError from the address check; call_tool reports it
        error = e
    return {"error": error}


def web_fetch(args):
    url = str(args.get("url") or "").strip()
    if not url:
        raise ToolError("url is empty")
    if "://" not in url:
        url = "https://" + url
    check_public_url(url)

    # The timeouts above count per network operation, so a server that sends a byte
    # every few seconds could stall the tool for minutes. Bound the whole fetch.
    deadline = time.monotonic() + FETCH_DEADLINE
    done = {}
    worker = threading.Thread(target=lambda: done.update(download(url, deadline)), daemon=True)
    worker.start()
    worker.join(FETCH_DEADLINE + 2)
    if worker.is_alive() or not done:
        raise ToolError(f"the page did not load within {FETCH_DEADLINE} seconds; try another result")
    if "error" in done:
        raise done["error"]
    final_url, ctype, charset, raw = done["url"], done["ctype"], done["charset"], done["raw"]

    decoded = raw.decode(guess_charset(raw, charset), "replace")
    if ctype in ("text/html", "application/xhtml+xml"):
        parser = TextExtractor()
        parser.feed(decoded)
        parser.close()
        title, text = parser.result()
    elif ctype.startswith("text/") or ctype in ("application/json", "application/xml"):
        title, text = "", decoded.strip()
    elif ctype == "application/pdf":
        raise ToolError("this is a PDF, which web_fetch can't read; try another result")
    else:
        raise ToolError(f"can't read this kind of content ({ctype}); try another result")

    if not text:
        raise ToolError("the page has no readable text (it may need JavaScript); try another result")
    if done["cut_short"]:
        text += f"\n\n[The page was still loading after {FETCH_DEADLINE} seconds; this is the part that arrived.]"
    total = len(text)
    if total > FETCH_MAX_CHARS:
        text = text[:FETCH_MAX_CHARS].rsplit(None, 1)[0]
        text += f"\n\n[Shortened: showing {len(text)} of {total} characters.]"
    header = f"# {title}\n" if title else ""
    return f"{header}URL: {final_url}\n\n{text}"


# --------------------------------------------------------------------------
# MCP server
# --------------------------------------------------------------------------

TOOLS = [
    {
        "name": "search",
        "description": (
            "Search the web. Use it for news, recent events, prices, opening hours, or any "
            "fact you are not sure about. Returns titles, URLs and short snippets. "
            "To read a result in full, pass its URL to web_fetch."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description": "Search words, as you would type them into a search engine."},
            },
            "required": ["query"],
        },
    },
    {
        "name": "fetch",
        "description": (
            "Read a web page and return its main text, shortened if it is long. "
            "Use it on a URL from web_search results or one the user gave you."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "Full http(s) URL of the page."},
            },
            "required": ["url"],
        },
    },
]

HANDLERS = {"search": web_search, "fetch": web_fetch}


def call_tool(name, args):
    handler = HANDLERS.get(name)
    if handler is None:
        return f"unknown tool: {name}", True
    try:
        return handler(args if isinstance(args, dict) else {}), False
    except ToolError as e:
        log(f"{name}: {e}")
        return str(e), True
    except Exception as e:  # never let one bad page kill the server
        log(f"{name}: unexpected {type(e).__name__}: {e}")
        return f"{name} failed: {type(e).__name__}: {e}", True


def handle(message):
    method = message.get("method")
    msg_id = message.get("id")
    params = message.get("params") or {}
    if msg_id is None:  # a notification, e.g. notifications/initialized
        return None

    def reply(result):
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    if method == "initialize":
        return reply({
            "protocolVersion": params.get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "pi-llm-web-search", "version": VERSION},
        })
    if method == "ping":
        return reply({})
    if method == "tools/list":
        return reply({"tools": TOOLS})
    if method == "tools/call":
        text, is_error = call_tool(params.get("name"), params.get("arguments") or {})
        return reply({"content": [{"type": "text", "text": text}], "isError": is_error})
    return {"jsonrpc": "2.0", "id": msg_id,
            "error": {"code": -32601, "message": f"method not found: {method}"}}


def serve():
    out = sys.stdout.buffer
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            log(f"ignoring malformed message: {line[:100]}")
            continue
        response = handle(message) if isinstance(message, dict) else None
        if response is not None:
            # errors="replace": a lone surrogate (from \ud800 in the input) becomes "?" instead
            # of crashing the write or producing JSON that strict parsers reject
            out.write(json.dumps(response, ensure_ascii=False).encode("utf-8", "replace") + b"\n")
            out.flush()


def main(argv):
    if len(argv) == 3 and argv[1] in ("--search", "--fetch"):
        tool = argv[1][2:]
        text, is_error = call_tool(tool, {"query" if tool == "search" else "url": argv[2]})
        print(text)
        return 1 if is_error else 0
    if len(argv) > 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
