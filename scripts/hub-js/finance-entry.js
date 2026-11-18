// ---------------------------------------------------------------------------
// Glue for the phone (LocalFinance.swift): the parts of the hub's lib/store.ts,
// lib/sync.ts, lib/holdings.ts and app/api/mobile/finance that aren't SQL or
// HTTP, copied as closely as possible so the app shows what the hub showed.
// Swift runs the queries and the SimpleFIN request and passes rows in as JSON;
// every function here takes one JSON string and returns one.
// ---------------------------------------------------------------------------
(function () {
  const { canonicalCategory, isBuiltInCategory, mergeCategoryOptions, normalizeCategory } = __require("lib/categories");
  const { accountSetErrors, institutionName } = __require("lib/simplefin");
  const { buildDashboard } = __require("lib/finance");
  const { detectRecurring } = __require("lib/recurring");
  const { bestSeries } = __require("lib/goal");

  const DEFAULT_GOAL = { target: 1_000_000, monthlyContribution: null, annualReturnPct: 7 };
  const epochSeconds = (value) => Math.floor(new Date(value).getTime() / 1000);

  function parseGoal(raw) {
    if (!raw) return DEFAULT_GOAL;
    try {
      return { ...DEFAULT_GOAL, ...JSON.parse(raw) };
    } catch {
      return DEFAULT_GOAL;
    }
  }

  /** components/dashboard/overview.tsx: the categories to offer first when tagging, most used first. */
  function rankCategories(transactions) {
    const counts = { out: new Map(), in: new Map() };
    for (const t of transactions) {
      const bucket = t.netEffect > 0 ? counts.in : counts.out;
      bucket.set(t.category, (bucket.get(t.category) ?? 0) + 1);
    }
    const ranked = (map, seed) => {
      for (const category of seed) if (!map.has(category)) map.set(category, 0);
      return [...map.entries()].sort((a, b) => b[1] - a[1]).map(([category]) => category);
    };
    return {
      out: ranked(counts.out, ["Food & Drinks", "Groceries", "Transport", "Lifestyle", "Bills & Utilities"]),
      in: ranked(counts.in, ["Income", "Transfers"]),
    };
  }

  // MARK: Finance page (store.ts loadDashboardData + GET /api/mobile/finance)

  function dashboard(json) {
    const I = JSON.parse(json);
    if (!I.accounts.length) return JSON.stringify({ configured: true, hasData: false, sync: I.sync });

    const categoryOverrides = new Map(I.overrides.map((row) => [row.transaction_id, canonicalCategory(row.category)]));
    const byAccount = new Map();
    for (const row of I.transactions) {
      const list = byAccount.get(row.account_id) ?? [];
      list.push({
        // Ids are stored as "<accountId>:<transactionId>"; hand back the bare id.
        id: row.id.startsWith(`${row.account_id}:`) ? row.id.slice(row.account_id.length + 1) : row.id,
        posted: epochSeconds(row.posted),
        amount: row.amount,
        description: row.description,
        payee: row.payee ?? undefined,
        memo: row.memo ?? undefined,
        pending: Boolean(row.pending),
      });
      byAccount.set(row.account_id, list);
    }
    const accounts = I.accounts.map((row) => ({
      id: row.id,
      name: row.name,
      currency: row.currency,
      balance: row.balance,
      "available-balance": row.available_balance ?? undefined,
      "balance-date": epochSeconds(row.balance_date),
      org: { name: row.institution },
      transactions: byAccount.get(row.id) ?? [],
    }));
    const customCategories = mergeCategoryOptions(
      I.custom.map((row) => canonicalCategory(row.name)),
      I.overrides.map((row) => canonicalCategory(row.category)),
    ).filter((name) => !isBuiltInCategory(name));
    const netWorthSnapshots = I.snapshots.map((row) => ({ date: row.date, value: Number(row.value) }));

    const board = buildDashboard({ errors: I.sync.notices, accounts }, I.historyDays, categoryOverrides, I.queue);
    const recurring = detectRecurring(board.transactions, new Set(I.ignored), I.now / 1000);
    const history = bestSeries(netWorthSnapshots, board.netWorthSeries);
    const categories = [...new Set([...customCategories, ...board.transactions.map((t) => t.category)])];
    return JSON.stringify({
      configured: true,
      hasData: true,
      sync: I.sync,
      historyDays: I.historyDays,
      dashboard: board,
      recurring,
      history,
      goal: parseGoal(I.goal),
      customCategories: categories,
      quickCategories: rankCategories(board.transactions),
    });
  }

  // MARK: Sync (sync.ts runSync, without the SQL)

  /** A SimpleFIN account set, as the rows to write. */
  function syncRows(json) {
    const set = JSON.parse(json);
    const connections = set.connections ?? [];
    const accounts = set.accounts.map((account) => ({
      id: account.id,
      name: account.name,
      institution: institutionName(account, connections),
      currency: account.currency || "USD",
      balance: String(account.balance),
      available_balance: account["available-balance"] ?? null,
      balance_date: new Date(account["balance-date"] * 1000).toISOString(),
      // The account without its transactions; those get their own rows.
      raw: JSON.stringify({ ...account, transactions: undefined }),
      // null when SimpleFIN sent no list, so pending rows aren't cleared on a balances-only answer.
      transactions: account.transactions
        ? account.transactions.map((t) => ({
          // SimpleFIN transaction ids are only unique within an account.
          id: `${account.id}:${t.id}`,
          posted: new Date((t.transacted_at ?? t.posted) * 1000).toISOString(),
          amount: String(t.amount),
          description: t.description ?? "",
          payee: t.payee ?? null,
          memo: t.memo ?? null,
          pending: Boolean(t.pending),
          raw: JSON.stringify(t),
        }))
        : null,
      holdings: holdingRows(account),
    }));
    let netWorth = null;
    try {
      netWorth = buildDashboard(set, 1).netWorth.toFixed(2);
    } catch {
      // Losing one reading isn't worth failing the sync over.
    }
    return JSON.stringify({ accounts, notices: accountSetErrors(set), netWorth });
  }

  // MARK: Investments (holdings.ts)

  const CLASS_BY_SYMBOL = {
    SPAXX: "Cash", FDRXX: "Cash", FRSXX: "Cash", FZFXX: "Cash", SWVXX: "Cash", VMFXX: "Cash", CORE: "Cash",
    SPY: "US stock funds", VOO: "US stock funds", IVV: "US stock funds", VTI: "US stock funds",
    QQQ: "US stock funds", QQQM: "US stock funds", FNILX: "US stock funds", FZROX: "US stock funds",
    FXAIX: "US stock funds", FSKAX: "US stock funds", SPGP: "US stock funds", SCHD: "US stock funds",
    SCHB: "US stock funds", VUG: "US stock funds", VTV: "US stock funds", SPLG: "US stock funds",
    VXUS: "International", VEA: "International", VWO: "International", IXUS: "International",
    FZILX: "International", FTIHX: "International", IEFA: "International", EFA: "International",
    XLE: "Energy", VDE: "Energy", XOP: "Energy",
    URA: "Nuclear & uranium", NUKZ: "Nuclear & uranium", SMR: "Nuclear & uranium",
    SMRF: "Nuclear & uranium", CCJ: "Nuclear & uranium", NLR: "Nuclear & uranium", OKLO: "Nuclear & uranium",
    IAU: "Gold", GLD: "Gold", GLDM: "Gold",
    BND: "Bonds", AGG: "Bonds", FXNAX: "Bonds", BNDX: "Bonds", TLT: "Bonds", SGOV: "Bonds",
  };

  function assetClassFor(symbol, description) {
    const known = CLASS_BY_SYMBOL[symbol.toUpperCase()];
    if (known) return known;
    const text = description.toLowerCase();
    if (/money market|cash reserves|sweep/.test(text)) return "Cash";
    if (/bond|treasury|income fund/.test(text)) return "Bonds";
    if (/gold|bullion/.test(text)) return "Gold";
    if (/uranium|nuclear/.test(text)) return "Nuclear & uranium";
    if (/energy|oil|gas/.test(text)) return "Energy";
    if (/international|intl|emerging|developed|ex-us|world/.test(text)) return "International";
    if (/s&p|500|total market|large cap|nasdaq-100|index/.test(text)) return "US stock funds";
    if (/\b(etf|fund|trust)\b/.test(text)) return "Other funds";
    return "Individual stocks";
  }

  function num(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
  }
  const round = (value) => Math.round(value * 100) / 100;

  function normalizeHolding(holding) {
    const symbol = (holding.symbol ?? "").trim().toUpperCase() || (holding.description ?? "").trim();
    if (!symbol) return null;
    const name = (holding.description ?? symbol).trim();
    const shares = num(holding.shares);
    const marketValue = num(holding.market_value);
    const isCash = assetClassFor(symbol, name) === "Cash";
    let costBasis = null;
    const basis = num(holding.cost_basis);
    const purchase = num(holding.purchase_price);
    if (basis > 0) costBasis = basis;
    else if (purchase > 0 && shares > 0) costBasis = Math.round(purchase * shares * 100) / 100;
    else if (isCash) costBasis = marketValue;
    return { symbol, name, shares, marketValue, costBasis, isCash };
  }

  function holdingsOf(raw) {
    const list = raw?.holdings;
    return Array.isArray(list) ? list : [];
  }

  /** recordHoldings for one account: today's row per symbol, lots of the same symbol added up. */
  function holdingRows(account) {
    const holdings = holdingsOf(account).map(normalizeHolding).filter((h) => h !== null);
    const bySymbol = new Map();
    for (const h of holdings) {
      const existing = bySymbol.get(h.symbol);
      if (!existing) {
        bySymbol.set(h.symbol, { ...h });
      } else {
        existing.shares += h.shares;
        existing.marketValue += h.marketValue;
        existing.costBasis = existing.costBasis !== null && h.costBasis !== null ? existing.costBasis + h.costBasis : null;
      }
    }
    return [...bySymbol.values()].map((r) => ({
      symbol: r.symbol, shares: r.shares.toFixed(6), market_value: r.marketValue.toFixed(2),
      cost_basis: r.costBasis === null ? null : r.costBasis.toFixed(2),
    }));
  }

  /** loadHoldings after its queries: accounts (raw parsed) and the snapshots since the window start. */
  function holdings(json) {
    const { accountRows, snapshotRows, today } = JSON.parse(json);
    const accounts = [];
    const positions = new Map();
    let asOf = null;

    for (const row of accountRows) {
      const list = holdingsOf(row.raw).map(normalizeHolding).filter((h) => h !== null);
      const balanceDate = Math.floor(new Date(row.balance_date).getTime() / 1000);
      asOf = Math.max(asOf ?? 0, balanceDate);
      let value = 0;
      let cash = 0;
      let costBasis = 0;
      let costedValue = 0;
      for (const h of list) {
        value += h.marketValue;
        if (h.isCash) cash += h.marketValue;
        if (h.costBasis !== null) {
          costBasis += h.costBasis;
          costedValue += h.marketValue;
        }
        const lot = {
          accountId: row.id, accountName: row.name, institution: row.institution,
          shares: h.shares, marketValue: h.marketValue, costBasis: h.costBasis,
        };
        const existing = positions.get(h.symbol);
        if (existing) {
          existing.shares += h.shares;
          existing.marketValue += h.marketValue;
          existing.costBasis = existing.costBasis !== null && h.costBasis !== null ? existing.costBasis + h.costBasis : null;
          existing.lots.push(lot);
        } else {
          positions.set(h.symbol, {
            symbol: h.symbol, name: h.name, assetClass: assetClassFor(h.symbol, h.name), isCash: h.isCash,
            shares: h.shares, price: 0, marketValue: h.marketValue, costBasis: h.costBasis, avgCost: null,
            gain: null, gainPct: null, weight: 0, dayChange: null, dayChangePct: null, lots: [lot], history: [],
          });
        }
      }
      const gain = costedValue - costBasis;
      accounts.push({
        id: row.id, name: row.name, institution: row.institution, balance: num(row.balance),
        value: round(value), cash: round(cash), costBasis: round(costBasis), gain: round(gain),
        gainPct: costBasis > 0 ? gain / costBasis : null, positions: list.length,
      });
    }

    // Per-symbol daily value and shares, summed across accounts.
    const symbolDays = new Map();
    const totalByDay = new Map();
    for (const s of snapshotRows) {
      const days = symbolDays.get(s.symbol) ?? new Map();
      const day = days.get(s.date) ?? { value: 0, shares: 0 };
      day.value += num(s.market_value);
      day.shares += num(s.shares);
      days.set(s.date, day);
      symbolDays.set(s.symbol, days);
      totalByDay.set(s.date, (totalByDay.get(s.date) ?? 0) + num(s.market_value));
    }

    const total = [...positions.values()].reduce((sum, p) => sum + p.marketValue, 0);
    let dayChange = 0;
    let previousTotal = 0;
    let anyDayChange = false;
    for (const position of positions.values()) {
      position.marketValue = round(position.marketValue);
      position.price = position.shares > 0 ? position.marketValue / position.shares : 0;
      position.avgCost = position.costBasis !== null && position.shares > 0 ? position.costBasis / position.shares : null;
      position.gain = position.costBasis !== null ? round(position.marketValue - position.costBasis) : null;
      position.gainPct = position.costBasis !== null && position.costBasis > 0 && !position.isCash
        ? (position.marketValue - position.costBasis) / position.costBasis : null;
      position.weight = total > 0 ? position.marketValue / total : 0;
      const days = symbolDays.get(position.symbol);
      position.history = days ? [...days.entries()].map(([date, d]) => ({ date, value: round(d.value) })) : [];
      if (!position.history.some((point) => point.date === today)) position.history.push({ date: today, value: position.marketValue });
      // Price move since the latest earlier day, so buying more shares doesn't read as a gain.
      const previous = days ? [...days.entries()].filter(([date]) => date < today).pop() : undefined;
      if (previous && previous[1].shares > 0 && !position.isCash) {
        const previousPrice = previous[1].value / previous[1].shares;
        if (previousPrice > 0) {
          position.dayChangePct = position.price / previousPrice - 1;
          position.dayChange = round((position.price - previousPrice) * position.shares);
          dayChange += position.dayChange;
          previousTotal += previousPrice * position.shares;
          anyDayChange = true;
        }
      }
    }

    const sorted = [...positions.values()].sort((a, b) => b.marketValue - a.marketValue);
    const allocationMap = new Map();
    for (const p of sorted) allocationMap.set(p.assetClass, (allocationMap.get(p.assetClass) ?? 0) + p.marketValue);
    const allocation = [...allocationMap.entries()]
      .map(([assetClass, value]) => ({ assetClass, value: round(value), share: total > 0 ? value / total : 0 }))
      .sort((a, b) => b.value - a.value);
    const history = [...totalByDay.entries()].map(([date, value]) => ({ date, value: round(value) }));
    if (!history.some((point) => point.date === today) && total > 0) history.push({ date: today, value: round(total) });

    const cash = sorted.filter((p) => p.isCash).reduce((sum, p) => sum + p.marketValue, 0);
    const costed = sorted.filter((p) => p.costBasis !== null && !p.isCash);
    const costBasis = costed.reduce((sum, p) => sum + (p.costBasis ?? 0), 0);
    const gain = costed.reduce((sum, p) => sum + p.marketValue, 0) - costBasis;
    return JSON.stringify({
      configured: true,
      hasHoldings: sorted.length > 0,
      asOf,
      totals: {
        value: round(total), cash: round(cash), invested: round(total - cash), costBasis: round(costBasis),
        gain: round(gain), gainPct: costBasis > 0 ? gain / costBasis : null,
        dayChange: anyDayChange ? round(dayChange) : null,
        dayChangePct: anyDayChange && previousTotal > 0 ? dayChange / previousTotal : null,
      },
      accounts,
      positions: sorted,
      allocation,
      history,
    });
  }

  // MARK: Tagging

  /** A category as typed, cleaned up the way the hub stores it; null when it isn't one. */
  function category(json) {
    return JSON.stringify({ category: normalizeCategory(JSON.parse(json)), builtIn: isBuiltInCategory(normalizeCategory(JSON.parse(json)) ?? "") });
  }

  // MARK: Fitness context (lib/fitness/context.ts, after its queries)

  /** Local "YYYY-MM-DD" and minutes after midnight in a time zone (google-calendar.ts hubDay, hubMinutes). */
  function zoned(timeZone) {
    const dayFormat = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
    const timeFormat = new Intl.DateTimeFormat("en-US", { timeZone, hourCycle: "h23", hour: "2-digit", minute: "2-digit" });
    const day = (date) => {
      const p = Object.fromEntries(dayFormat.formatToParts(date).map((x) => [x.type, x.value]));
      return `${p.year}-${p.month}-${p.day}`;
    };
    const minutes = (date) => {
      const p = Object.fromEntries(timeFormat.formatToParts(date).map((x) => [x.type, x.value]));
      return (Number(p.hour) % 24) * 60 + Number(p.minute);
    };
    return { day, minutes };
  }

  /** Timed events that are meetings or plans: not all-day, not birthdays, not 8-hour blocks. */
  function counts(e) {
    if (e.allDay || e.birthday) return false;
    const length = new Date(e.end).getTime() - new Date(e.start).getTime();
    return length > 0 && length <= 8 * 3_600_000;
  }

  function calendarDays(events, tz) {
    const byDay = new Map();
    for (const e of events.filter(counts)) {
      const start = new Date(e.start);
      const end = new Date(e.end);
      const day = tz.day(start);
      const from = tz.minutes(start);
      const to = tz.day(end) === day ? tz.minutes(end) : 24 * 60;
      if (!byDay.has(day)) byDay.set(day, []);
      byDay.get(day).push({ start: from, end: Math.max(from, to) });
    }
    return [...byDay.entries()]
      .map(([day, list]) => {
        list.sort((a, b) => a.start - b.start);
        let minutes = 0;
        let backToBack = 0;
        let cursor = -1;
        let previousEnd = null;
        for (const m of list) {
          if (previousEnd !== null && m.start - previousEnd >= 0 && m.start - previousEnd < 10) backToBack++;
          const from = Math.max(m.start, cursor);
          if (m.end > from) minutes += m.end - from;
          cursor = Math.max(cursor, m.end);
          previousEnd = previousEnd === null ? m.end : Math.max(previousEnd, m.end);
        }
        return {
          day,
          meetingHours: Math.round((minutes / 60) * 100) / 100,
          meetings: list.length,
          firstStart: list[0]?.start ?? null,
          lastEnd: list.reduce((max, m) => Math.max(max, m.end), 0) || null,
          backToBack,
        };
      })
      .sort((a, b) => (a.day < b.day ? 1 : -1));
  }

  const DELIVERY = /doordash|uber ?eats|grubhub|seamless|caviar|postmates|gopuff/i;
  const RIDESHARE = /\buber\b|lyft/i;
  const NOT_DRINKS = /coffee|cafe|caf[eé]|espresso|bakery|tea\b|boba|juice|bagel|donut|doughnut|market|grocery|pharmacy|cvs|walgreens|deli\b|pizza|sushi|ramen|burrito|taco|shake shack|sweetgreen|chipotle|tatte|bluestone|equator/i;
  const BARISH = /\bbar\b|\bpub\b|tavern|saloon|brew|taproom|tap ?room|tap ?house|ale ?house|cocktail|lounge|wine|liquor|spirits|beer|biergarten|beer garden|speakeasy|\bhall\b|social|\bclub\b|distill|cantina|izakaya|bodega bar/i;
  const VENUE = /^(tst\s?\*|sq\s?\*|toast|resy)/i;

  /** "TST*CITYSIDE TAVERN - BR" -> "Cityside Tavern". */
  function merchantName(description) {
    const cleaned = description
      .replace(/^(tst\s?\*|sq\s?\*|aplpay\s+|dd\s?\*|sp\s?\*)/i, "")
      .replace(/\s+-\s+.*$/, "")
      .replace(/\s{2,}.*$/, "")
      .replace(/\s+\d{2,}.*$/, "")
      .trim();
    return cleaned.toLowerCase().replace(/\b([a-z])/g, (c) => c.toUpperCase()).slice(0, 40);
  }

  /** SimpleFIN's transacted_at is often a placeholder at midnight UTC; only other times are real. */
  const realTime = (at) => at.getUTCHours() !== 0 || at.getUTCMinutes() !== 0;

  function likelihood(row, merchant, memory, tz) {
    const taught = memory.get(merchant);
    if (taught && taught.yes + taught.no >= 1) return (taught.yes + 0.5) / (taught.yes + taught.no + 1);
    const text = `${row.payee ?? ""} ${row.description}`;
    const amount = -Number(row.amount);
    if (DELIVERY.test(text) || RIDESHARE.test(text) || NOT_DRINKS.test(text) || amount < 12) return 0;
    let p = BARISH.test(text) ? 0.6 : VENUE.test(row.description) ? 0.2 : 0;
    if (p === 0) return 0;
    if (realTime(row.at)) {
      const minutes = tz.minutes(row.at);
      if (minutes >= 17 * 60 || minutes < 4 * 60) p += 0.25;
      else if (minutes < 15 * 60) p -= 0.15;
    }
    if (amount >= 40) p += 0.1;
    return Math.max(0, Math.min(0.95, p));
  }

  /**
   * Input: { now (ms), timeZone, events (CalendarEvent[] or null), rows: [{ id, at, amount, description, payee }],
   * memory: [{ merchant, yes, no }], answered: [night] }.
   */
  function context(json) {
    const I = JSON.parse(json);
    const tz = zoned(I.timeZone);
    const memory = new Map(I.memory.map((r) => [r.merchant, { yes: Number(r.yes), no: Number(r.no) }]));
    const nightOf = (at) => tz.day(new Date(at.getTime() - 5 * 3_600_000));
    const nights = new Map();
    const candidates = [];
    for (const raw of I.rows) {
      const row = { ...raw, at: new Date(raw.at), payee: raw.payee || null };
      const night = nightOf(row.at);
      const amount = -Number(row.amount);
      const merchant = row.payee ? merchantName(row.payee) : merchantName(row.description);
      const text = `${row.payee ?? ""} ${row.description}`;
      const n = nights.get(night) ?? { night, bar: 0, delivery: 0, rideshare: 0 };
      const p = likelihood(row, merchant, memory, tz);
      if (DELIVERY.test(text)) n.delivery += amount;
      else if (RIDESHARE.test(text)) n.rideshare += amount;
      else if (p >= 0.5) n.bar += amount;
      nights.set(night, n);
      if (p >= 0.35) candidates.push({ id: row.id, night, merchant, amount, likelihood: Math.round(p * 100) / 100 });
    }
    // Only the last four nights, and only ones the drinks log hasn't answered.
    const recent = tz.day(new Date(I.now - 4 * 86_400_000));
    const answered = new Set(I.answered);
    const barCharges = candidates.filter((c) => c.night >= recent && !answered.has(c.night));
    const spending = [...nights.values()]
      .map((n) => ({ ...n, bar: round(n.bar), delivery: round(n.delivery), rideshare: round(n.rideshare) }))
      .sort((a, b) => (a.night < b.night ? 1 : -1));
    return JSON.stringify({ calendar: I.events ? calendarDays(I.events, tz) : null, spending, barCharges });
  }

  // MARK: Jarvis (lib/agent/voice.ts showFinance, lib/agent/tools.ts finance tools)

  const { isCountable, isSpendingOffset } = __require("lib/finance");
  const round2 = (n) => Math.round(n * 100) / 100;

  /** The instant of a local wall time in a time zone (google-calendar.ts hubInstant). */
  function zonedInstant(day, minutes, timeZone) {
    const offsetMinutes = (at) => {
      const parts = new Intl.DateTimeFormat("en-US", {
        timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
      }).formatToParts(at);
      const get = (type) => Number(parts.find((p) => p.type === type)?.value);
      const wall = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour") % 24, get("minute"), get("second"));
      return Math.round((wall - at.getTime()) / 60_000);
    };
    const naive = new Date(`${day}T00:00:00Z`).getTime() + minutes * 60_000;
    return new Date(naive - offsetMinutes(new Date(naive)) * 60_000);
  }

  /** The dashboard's transactions etc., as buildDashboard made them (input: dashboard()'s rows). */
  function board(I) {
    const page = JSON.parse(dashboard(JSON.stringify(I)));
    if (!page.hasData) throw new Error("No finance data has been synced yet.");
    return page;
  }

  /** Input: { rows (dashboard's), input: { focus, period, category?, text? }, timeZone }. */
  function voiceFinance(json) {
    const { rows, input, timeZone } = JSON.parse(json);
    let d;
    try {
      d = board(rows).dashboard;
    } catch (error) {
      return JSON.stringify({ output: { error: error.message } });
    }
    const tz = zoned(timeZone);
    const today = tz.day(new Date());
    const [y, m] = today.split("-").map(Number);
    const pad = (n) => String(n).padStart(2, "0");
    const at = (day) => zonedInstant(day, 0, timeZone).getTime() / 1000;
    const now = Date.now() / 1000;
    const range = {
      thisMonth: () => ({ from: at(`${y}-${pad(m)}-01`), to: now, label: "This month" }),
      lastMonth: () => {
        const py = m === 1 ? y - 1 : y;
        const pm = m === 1 ? 12 : m - 1;
        return { from: at(`${py}-${pad(pm)}-01`), to: at(`${y}-${pad(m)}-01`), label: "Last month" };
      },
      last30Days: () => ({ from: now - 30 * 86_400, to: now, label: "Last 30 days" }),
      last90Days: () => ({ from: now - 90 * 86_400, to: now, label: "Last 90 days" }),
      thisYear: () => ({ from: at(`${y}-01-01`), to: now, label: "This year" }),
    };
    const { from, to, label } = (range[input.period] ?? range.thisMonth)();
    const monthLabel = (ym) => new Date(`${ym}-15T12:00:00Z`).toLocaleString("en-US", { month: "short", timeZone: "UTC" });
    const rowOf = (t) => {
      const date = new Date(t.posted * 1000).toLocaleString("en-US", { month: "short", day: "numeric", timeZone });
      return { title: t.payee || t.description, subtitle: `${date} · ${t.category}`, amount: round2(t.netEffect) };
    };
    const monthlySpend = (category, months = 6) => {
      const sums = new Map();
      for (const t of d.transactions) {
        if (!isCountable(t) || (t.netEffect >= 0 && !isSpendingOffset(t))) continue;
        if (category && t.category.toLowerCase() !== category.toLowerCase()) continue;
        const ym = tz.day(new Date(t.posted * 1000)).slice(0, 7);
        sums.set(ym, (sums.get(ym) ?? 0) - t.netEffect);
      }
      const out = [];
      for (let i = months - 1; i >= 0; i--) {
        const ym = new Date(Date.UTC(y, m - 1 - i, 1)).toISOString().slice(0, 7);
        out.push({ label: monthLabel(ym), value: round2(Math.max(0, sums.get(ym) ?? 0)) });
      }
      return out;
    };
    const inPeriod = d.transactions.filter((t) => t.posted >= from && t.posted < to);
    const category = input.category?.trim() || null;
    let view;
    switch (input.focus) {
      case "netWorth": {
        const series = d.netWorthSeries;
        const step = Math.max(1, Math.ceil(series.length / 30));
        view = {
          kind: "finance", title: "Net worth", subtitle: "Assets minus debts", currency: d.currency,
          stats: [
            { label: "Net worth", value: round2(d.netWorth), format: "currency", detail: `${d.netWorthChange >= 0 ? "Up" : "Down"} ${Math.abs(Math.round(d.netWorthChange)).toLocaleString("en-US")}`, tone: d.netWorthChange >= 0 ? "positive" : "negative" },
            { label: "Assets", value: round2(d.totalAssets), format: "currency" },
            { label: "Debts", value: round2(d.totalLiabilities), format: "currency" },
          ],
          chart: {
            style: "line",
            points: series.filter((_, i) => i % step === 0 || i === series.length - 1)
              .map((p) => ({ label: new Date(p.date).toLocaleString("en-US", { month: "short", day: "numeric", timeZone: "UTC" }), value: round2(p.value) })),
          },
          rows: [],
        };
        break;
      }
      case "spending": {
        const spent = inPeriod.filter((t) => isCountable(t) && (t.netEffect < 0 || isSpendingOffset(t)) && (!category || t.category.toLowerCase() === category.toLowerCase()));
        const total = Math.max(0, spent.reduce((s, t) => s - t.netEffect, 0));
        if (category) {
          view = {
            kind: "finance", title: category, subtitle: label, currency: d.currency,
            stats: [{ label: `${category} · ${label.toLowerCase()}`, value: round2(total), format: "currency" }, { label: "Transactions", value: spent.length, format: "count" }],
            chart: { style: "bar", points: monthlySpend(category) },
            rows: [...spent].sort((a, b) => a.netEffect - b.netEffect).slice(0, 5).map(rowOf),
          };
        } else {
          const byCategory = new Map();
          for (const t of spent) byCategory.set(t.category, (byCategory.get(t.category) ?? 0) - t.netEffect);
          view = {
            kind: "finance", title: "Spending", subtitle: label, currency: d.currency,
            stats: [{ label: `Spent · ${label.toLowerCase()}`, value: round2(total), format: "currency" }],
            chart: { style: "hbar", points: [...byCategory.entries()].filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1]).slice(0, 6).map(([c, v]) => ({ label: c, value: round2(v) })) },
            rows: [],
          };
        }
        break;
      }
      case "income": {
        const earned = inPeriod.filter((t) => isCountable(t) && t.netEffect > 0 && !isSpendingOffset(t));
        const total = earned.reduce((s, t) => s + t.netEffect, 0);
        view = {
          kind: "finance", title: "Income", subtitle: label, currency: d.currency,
          stats: [{ label: `Income · ${label.toLowerCase()}`, value: round2(total), format: "currency", tone: "positive" }],
          chart: { style: "bar", points: d.cashFlow.slice(-6).map((mo) => ({ label: monthLabel(mo.month), value: round2(mo.income) })) },
          rows: [...earned].sort((a, b) => b.netEffect - a.netEffect).slice(0, 5).map(rowOf),
        };
        break;
      }
      case "cashFlow":
        view = {
          kind: "finance", title: "Cash flow", subtitle: "Last 30 days", currency: d.currency,
          stats: [
            { label: "In", value: round2(d.income30d), format: "currency", tone: "positive" },
            { label: "Out", value: round2(d.spending30d), format: "currency" },
            { label: "Net", value: round2(d.netFlow30d), format: "currency", tone: d.netFlow30d >= 0 ? "positive" : "negative" },
          ],
          chart: { style: "bar", points: d.cashFlow.slice(-6).map((mo) => ({ label: monthLabel(mo.month), value: round2(mo.net) })) },
          rows: [],
        };
        break;
      case "accounts":
        view = {
          kind: "finance", title: "Accounts", subtitle: `${d.accounts.length} connected`, currency: d.currency,
          stats: [{ label: "Cash", value: round2(d.cash), format: "currency" }, { label: "Debts", value: round2(d.totalLiabilities), format: "currency" }],
          chart: null,
          rows: d.accounts.slice(0, 8).map((a) => ({ title: a.name, subtitle: a.institution, amount: round2(a.contribution) })),
        };
        break;
      case "transactions": {
        const needle = input.text?.toLowerCase();
        const matched = inPeriod.filter((t) => (!category || t.category.toLowerCase() === category.toLowerCase())
          && (!needle || `${t.description} ${t.payee} ${t.accountName}`.toLowerCase().includes(needle)));
        const total = matched.reduce((s, t) => s + t.netEffect, 0);
        view = {
          kind: "finance", title: input.text ? `“${input.text}”` : category ?? "Transactions", subtitle: label, currency: d.currency,
          stats: [{ label: "Total", value: round2(Math.abs(total)), format: "currency", tone: total >= 0 ? "positive" : undefined }, { label: "Transactions", value: matched.length, format: "count" }],
          chart: null,
          rows: [...matched].sort((a, b) => b.posted - a.posted).slice(0, 6).map(rowOf),
        };
        break;
      }
      default: {
        const month = d.monthSpending;
        view = {
          kind: "finance", title: "Overview", subtitle: "Where things stand", currency: d.currency,
          stats: [
            { label: "Net worth", value: round2(d.netWorth), format: "currency", detail: `${d.netWorthChange >= 0 ? "+" : ""}${Math.round(d.netWorthChange).toLocaleString("en-US")} over the period`, tone: d.netWorthChange >= 0 ? "positive" : "negative" },
            { label: "Spent this month", value: round2(month.total), format: "currency", detail: `vs ${Math.round(month.lastMonthToDate).toLocaleString("en-US")} last month to date`, tone: month.total <= month.lastMonthToDate ? "positive" : "negative" },
            { label: "Cash", value: round2(d.cash), format: "currency" },
          ],
          chart: { style: "bar", points: monthlySpend(null) },
          rows: [],
        };
      }
    }
    return JSON.stringify({
      output: {
        currency: view.currency, title: view.title, period: view.subtitle,
        stats: view.stats.map((s) => ({ [s.label]: s.value })),
        ...(view.chart ? { chart: view.chart.points } : {}),
        ...(view.rows.length ? { rows: view.rows } : {}),
      },
      view,
    });
  }

  /** The chat agent's getFinanceSummary. Input: { rows (dashboard's) }. */
  function financeSummary(json) {
    const { rows } = JSON.parse(json);
    try {
      const page = board(rows);
      const d = page.dashboard;
      return JSON.stringify({
        currency: d.currency,
        lastSyncedAt: page.sync.lastSuccessAt ? new Date(page.sync.lastSuccessAt).toISOString() : null,
        historyDays: page.historyDays,
        netWorth: round2(d.netWorth), netWorthChange: round2(d.netWorthChange),
        totalAssets: round2(d.totalAssets), totalLiabilities: round2(d.totalLiabilities),
        last30Days: { income: round2(d.income30d), spending: round2(d.spending30d), net: round2(d.netFlow30d) },
        accounts: d.accounts.map((a) => ({ name: a.name, institution: a.institution, kind: a.kind, balance: round2(a.contribution) })),
        spendingByCategory: d.spending.byCategory.slice(0, 10).map((c) => ({ category: c.category, amount: round2(c.amount), sharePct: Math.round(c.share * 100) })),
        monthlyCashFlow: d.cashFlow.map((mo) => ({ ...mo, income: round2(mo.income), spending: round2(mo.spending), net: round2(mo.net) })),
      });
    } catch (error) {
      return JSON.stringify({ error: error.message || "Couldn't load finances." });
    }
  }

  /** The chat agent's searchTransactions. Input: { rows, text?, category?, days, limit }. */
  function searchTransactions(json) {
    const { rows, text, category, days = 30, limit = 25 } = JSON.parse(json);
    try {
      const d = board(rows).dashboard;
      const since = Date.now() / 1000 - days * 86_400;
      const needle = text?.toLowerCase();
      const matched = d.transactions.filter((t) => t.posted >= since
        && (!category || t.category.toLowerCase() === category.toLowerCase())
        && (!needle || `${t.description} ${t.payee} ${t.accountName}`.toLowerCase().includes(needle)));
      const total = matched.reduce((s, t) => s + t.netEffect, 0);
      return JSON.stringify({
        matched: matched.length,
        netTotal: round2(total),
        transactions: matched.slice(0, limit).map((t) => ({
          date: new Date(t.posted * 1000).toISOString().slice(0, 10), description: t.payee || t.description,
          amount: round2(t.amount), category: t.category, account: t.accountName, pending: t.pending || undefined,
        })),
      });
    } catch (error) {
      return JSON.stringify({ error: error.message || "Couldn't load transactions." });
    }
  }

  globalThis.Finance = { dashboard, syncRows, holdings, category, context, voiceFinance, financeSummary, searchTransactions };
})();
