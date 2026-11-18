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

  globalThis.Finance = { dashboard, syncRows, holdings, category };
})();
