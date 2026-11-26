// Bilhetinho · Coração (fase 2): conhecer quem está na festa.
// Regras no banco: supabase/002_coracao.sql
import { sb, esc, errMsg, toast } from "/assets/common.js";

const BUCKET = "heart-photos";
const MSG = {
  drink: "🍸 Te pago um drink?",
  bar: "📍 Te encontro no bar?",
  dancar: "💃 Bora dançar?",
  oi: "👋 Oi! Gostei de você",
  sim: "✅ Bora!",
  nao: "🙏 Agora não, obrigado"
};
const ASKS = ["drink", "bar", "dancar", "oi"];
const GENDERS = [["mulher", "Mulher"], ["homem", "Homem"], ["nao_binario", "Não-binário"]];
const INTERESTS = [["mulheres", "Mulheres"], ["homens", "Homens"], ["todos", "Todos"]];
const REASONS = ["Perfil falso", "Foto imprópria", "Comportamento ofensivo", "Parece menor de idade"];
const heartSvg = `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 21s-7.5-4.6-9.6-9.3C.9 8.3 3 4.5 6.7 4.5c2.1 0 3.6 1.2 4.4 2.5.2.3.6.3.8 0 .8-1.3 2.3-2.5 4.4-2.5 3.7 0 5.8 3.8 4.3 7.2C18.6 16.4 12 21 12 21z"/></svg>`;

export function createHeart({ getEv, me, getBody, isOpen, setBadge, getName, artist }) {
  let prof = undefined;          // undefined: ainda não carregado; null: sem perfil
  let view = "conhecer";         // conhecer | matches | chat
  let deck = [], matches = [], chatMatch = null, chatMsgs = [];
  let coords = null, adult = false, form = { gender: null, interest: null, nickname: "", find: "", photo: null };
  const urls = {};               // user_id -> URL assinada da foto

  const ev = () => getEv();
  const body = () => getBody();
  const photoPath = uid => `${ev().id}/${uid}/foto.jpg`;

  async function loadProfile() {
    const { data } = await sb.from("heart_profiles").select("*").eq("event_id", ev().id).eq("user_id", me).maybeSingle();
    prof = data || null;
  }
  async function signPhotos(uids) {
    const need = uids.filter(u => !urls[u]);
    if (!need.length) return;
    const { data } = await sb.storage.from(BUCKET).createSignedUrls(need.map(photoPath), 3600);
    (data || []).forEach((d, i) => { if (d.signedUrl) urls[need[i]] = d.signedUrl; });
  }

  /* ---------- Tempo real: matches e mensagens, mesmo fora da aba ---------- */
  function listen() {
    sb.channel("coracao-" + ev().id + "-" + me)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "heart_matches", filter: "event_id=eq." + ev().id }, async p => {
        if (![p.new.user_a, p.new.user_b].includes(me)) return;
        await loadMatches();
        const m = matches.find(x => x.match_id === p.new.id);
        if (m) toast(`Deu match com <b>${esc(m.nickname)}</b>! ❤️`);
        if (!isOpen()) setBadge(true); else if (view === "matches") renderMatches();
      })
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "heart_messages" }, async p => {
        const msg = p.new;
        if (chatMatch && msg.match_id === chatMatch.match_id) {
          if (!chatMsgs.some(x => x.id === msg.id)) chatMsgs.push(msg);
          if (isOpen() && view === "chat") renderChat();
        }
        if (msg.from_user === me) return;
        if (!matches.some(m => m.match_id === msg.match_id)) await loadMatches();
        const m = matches.find(x => x.match_id === msg.match_id);
        if (m && !(isOpen() && view === "chat" && chatMatch?.match_id === msg.match_id)) {
          toast(`<b>${esc(m.nickname)}</b>: ${esc(MSG[msg.kind])}`);
          m.unread = true;
          if (!isOpen()) setBadge(true); else if (view === "matches") renderMatches();
        }
      })
      .subscribe();
  }

  /* ---------- Entrada ---------- */
  async function render() {
    setBadge(false);
    if (prof === undefined) {
      body().innerHTML = `<div class="center"><div class="spinner" aria-label="Carregando"></div></div>`;
      await loadProfile();
    }
    if (prof && prof.hidden) return renderRemoved();
    if (!prof || !prof.has_photo) return coords ? renderForm() : renderIntro();
    if (view === "chat" && chatMatch) return renderChat();
    if (view === "matches") return renderMatches();
    return renderDeck();
  }

  function renderRemoved() {
    body().innerHTML = `<div class="center"><span class="heart-core big gray" aria-hidden="true">${heartSvg}</span>
      <h1 class="title">Seu perfil foi removido desta festa</h1>
      <p>Isso acontece depois de denúncias ou por decisão da organização. Você continua podendo pedir músicas.</p></div>`;
  }

  function renderIntro(errorHtml = "") {
    const noVenue = ev().venue_lat == null;
    body().innerHTML = `
      <div class="soon-hero">
        <span class="heart-core big" aria-hidden="true">${heartSvg}</span>
        <h1 class="title">Conheça quem está na festa</h1>
        <p class="lead">Curta quem te chamou atenção. Se for recíproco, vocês podem se chamar para um drink ou para dançar.</p>
      </div>
      <ul class="soon-list">
        <li><b>Só quem está aqui.</b> Conferimos sua localização uma vez, na entrada. Ela não é guardada nem mostrada.</li>
        <li><b>Match só quando os dois querem.</b> Ninguém fala com você sem um match.</li>
        <li><b>Tudo some quando a festa acaba</b>, inclusive sua foto.</li>
      </ul>
      ${errorHtml ? `<div class="notice">${errorHtml}</div>` : ""}
      ${noVenue ? `<div class="notice">O coração ainda não foi ativado nesta festa. Ele liga quando o tablet do palco registra o local do show.</div>` : `
      <label class="check-line"><input type="checkbox" id="hAdult" ${adult ? "checked" : ""}> <span>Tenho <b>18 anos ou mais</b></span></label>
      <button class="cta heart-cta" type="button" id="hEnter" ${adult ? "" : "disabled"}>Entrar no coração</button>`}`;
    const chk = document.getElementById("hAdult");
    chk?.addEventListener("change", () => { adult = chk.checked; document.getElementById("hEnter").disabled = !adult; });
    document.getElementById("hEnter")?.addEventListener("click", locate);
  }

  function locate() {
    const btn = document.getElementById("hEnter");
    if (!navigator.geolocation) return renderIntro("Este navegador não informa a localização. Tente abrir o QR da festa pelo Chrome ou Safari.");
    btn.disabled = true; btn.textContent = "Confirmando que você está na festa…";
    navigator.geolocation.getCurrentPosition(
      pos => { coords = { lat: pos.coords.latitude, lng: pos.coords.longitude, acc: pos.coords.accuracy }; renderForm(); },
      err => {
        if (err.code === 1) renderIntro(`Precisamos da sua localização só para confirmar que você está na festa. Libere em <b>Ajustes do navegador → Localização</b> (ou no cadeado ao lado do endereço) e toque em Entrar de novo.`);
        else renderIntro("Não conseguimos pegar sua localização agora. Vá para um lugar mais aberto e tente de novo.");
      },
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 60000 });
  }

  function renderForm() {
    if (!form.nickname) form.nickname = (prof?.nickname || getName() || "").slice(0, 20);
    if (prof) { form.gender ||= prof.gender; form.interest ||= prof.interest; form.find ||= prof.find_me; }
    const chips = (list, key) => list.map(([v, l]) => `<button type="button" class="chip-opt" data-${key}="${v}" aria-pressed="${form[key] === v}">${l}</button>`).join("");
    body().innerHTML = `
      <h1 class="title">Seu perfil desta noite</h1>
      <p class="lead">Só quem está no coração desta festa vê, e ele some quando a festa acaba.</p>
      <div class="selfie-box">
        <label for="hPhoto" class="selfie ${form.photo ? "has" : ""}">
          ${form.photo ? `<img src="${form.photo.url}" alt="Sua selfie">` : `<span>📷</span><b>Tirar selfie</b>`}
        </label>
        <input type="file" id="hPhoto" accept="image/*" capture="user" hidden>
        <p class="hint">Uma foto sua, tirada agora. ${form.photo ? `<label for="hPhoto" class="link-like">Tirar outra</label>` : ""}</p>
      </div>
      <div class="field"><label for="hNick">Como quer ser chamado(a)</label><input class="inp" id="hNick" maxlength="20" value="${esc(form.nickname)}"></div>
      <div class="field"><label for="hFind">Como te achar (opcional)</label><input class="inp" id="hFind" maxlength="60" placeholder="Ex.: camisa vermelha, perto do bar" value="${esc(form.find)}"></div>
      <div class="field"><span class="lbl">Sou</span><div class="chips">${chips(GENDERS, "gender")}</div></div>
      <div class="field"><span class="lbl">Quero conhecer</span><div class="chips">${chips(INTERESTS, "interest")}</div></div>
      <button class="cta heart-cta" type="button" id="hSave">Pronto, quero conhecer gente</button>`;
    document.getElementById("hPhoto").addEventListener("change", async e => {
      const f = e.target.files?.[0];
      if (!f) return;
      try { form.photo = await shrink(f); renderForm(); } catch (_) { toast("Não deu para usar essa foto. Tente tirar outra.", true); }
    });
    document.getElementById("hNick").addEventListener("input", e => form.nickname = e.target.value);
    document.getElementById("hFind").addEventListener("input", e => form.find = e.target.value);
    body().querySelectorAll("[data-gender]").forEach(b => b.addEventListener("click", () => { form.gender = b.dataset.gender; renderForm(); }));
    body().querySelectorAll("[data-interest]").forEach(b => b.addEventListener("click", () => { form.interest = b.dataset.interest; renderForm(); }));
    document.getElementById("hSave").addEventListener("click", save);
  }

  // Reduz a foto para no máximo 720 px e JPEG, para subir rápido.
  async function shrink(file) {
    const img = await new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = URL.createObjectURL(file); });
    const max = 720, k = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
    const c = document.createElement("canvas");
    c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    const blob = await new Promise(r => c.toBlob(r, "image/jpeg", 0.8));
    if (!blob) throw new Error("foto");
    return { blob, url: URL.createObjectURL(blob) };
  }

  async function save() {
    const nick = form.nickname.trim();
    if (!form.photo) return toast("Tire uma selfie para entrar no coração.", true);
    if (nick.length < 2) return toast("Escreva como quer ser chamado(a).", true);
    if (!form.gender || !form.interest) return toast("Escolha o que você é e quem quer conhecer.", true);
    const btn = document.getElementById("hSave"); btn.disabled = true; btn.textContent = "Entrando…";
    try {
      const { data, error } = await sb.rpc("heart_join", {
        p_event: ev().id, p_lat: coords.lat, p_lng: coords.lng, p_accuracy: coords.acc,
        p_nickname: nick, p_find_me: form.find.trim(), p_gender: form.gender, p_interest: form.interest, p_adult: adult
      });
      if (error) throw error;
      prof = data;
      const up = await sb.storage.from(BUCKET).upload(photoPath(me), form.photo.blob, { upsert: true, contentType: "image/jpeg" });
      if (up.error) throw up.error;
      const r = await sb.rpc("heart_photo_ready", { p_event: ev().id });
      if (r.error) throw r.error;
      prof.has_photo = true;
      urls[me] = form.photo.url;
      view = "conhecer"; deck = [];
      toast("Pronto! Agora é só curtir quem te chamou atenção.");
      render();
    } catch (e) {
      const m = String(e.message || e);
      if (m.includes("longe_da_festa")) { coords = null; renderIntro("Parece que você não está no local da festa. Se estiver, vá para um lugar mais aberto e tente de novo."); return; }
      toast(esc(errMsg(e)), true);
      btn.disabled = false; btn.textContent = "Pronto, quero conhecer gente";
    }
  }

  /* ---------- Conhecer ---------- */
  function tabs(active) {
    const unread = matches.filter(m => m.unread).length;
    return `<div class="seg-tabs" role="tablist">
      <button role="tab" type="button" data-hv="conhecer" aria-selected="${active === "conhecer"}">Conhecer</button>
      <button role="tab" type="button" data-hv="matches" aria-selected="${active === "matches"}">Matches${matches.length ? ` <span class="n">${matches.length}</span>` : ""}${unread ? ` <span class="dot-red"></span>` : ""}</button>
    </div>`;
  }
  function wireTabs() {
    body().querySelectorAll("[data-hv]").forEach(b => b.addEventListener("click", () => { view = b.dataset.hv; render(); }));
  }

  async function loadDeck() {
    const { data, error } = await sb.rpc("heart_deck", { p_event: ev().id });
    if (error) { toast(esc(errMsg(error)), true); deck = []; return; }
    deck = data || [];
    await signPhotos(deck.map(d => d.user_id));
  }
  async function loadMatches() {
    const { data } = await sb.rpc("heart_my_matches", { p_event: ev().id });
    const old = Object.fromEntries(matches.map(m => [m.match_id, m.unread]));
    matches = (data || []).map(m => ({ ...m, unread: !!old[m.match_id] }));
    await signPhotos(matches.map(m => m.user_id));
  }

  async function renderDeck() {
    if (!deck.length) { body().innerHTML = `<div class="center"><div class="spinner"></div></div>`; await Promise.all([loadDeck(), loadMatches()]); }
    const p = deck[0];
    body().innerHTML = `
      ${tabs("conhecer")}
      ${p ? `
        <article class="person">
          <img class="person-photo" src="${esc(urls[p.user_id] || "")}" alt="Foto de ${esc(p.nickname)}">
          <div class="person-info"><b>${esc(p.nickname)}</b>${p.find_me ? `<span>${esc(p.find_me)}</span>` : ""}</div>
          <button type="button" class="person-more" id="hMore" aria-label="Denunciar ou bloquear">⋯</button>
        </article>
        <div class="swipe-btns">
          <button type="button" class="round pass" id="hPass" aria-label="Passar">✕</button>
          <button type="button" class="round like" id="hLike" aria-label="Curtir">${heartSvg}</button>
        </div>` : `
        <div class="center" style="min-height:45vh">
          <p>Por enquanto é só. Novas pessoas aparecem conforme entram no coração.</p>
          <button class="reload-btn" type="button" id="hReload">↻ Atualizar</button>
        </div>`}
      <button type="button" class="link-like leave" id="hLeave">Sair do coração</button>`;
    wireTabs();
    document.getElementById("hReload")?.addEventListener("click", () => { deck = []; renderDeck(); });
    document.getElementById("hPass")?.addEventListener("click", () => like(p, false));
    document.getElementById("hLike")?.addEventListener("click", () => like(p, true));
    document.getElementById("hMore")?.addEventListener("click", () => openReport(p.user_id, p.nickname, () => { deck.shift(); renderDeck(); }));
    document.getElementById("hLeave").addEventListener("click", leave);
  }

  async function like(p, liked) {
    body().querySelectorAll(".round").forEach(b => b.disabled = true);
    const { data, error } = await sb.rpc("heart_like", { p_event: ev().id, p_to: p.user_id, p_liked: liked });
    if (error) { toast(esc(errMsg(error)), true); }
    deck.shift();
    if (data?.match) {
      await loadMatches();
      const m = matches.find(x => x.match_id === data.match_id);
      return showMatch(m || { ...p, match_id: data.match_id });
    }
    if (!deck.length) await loadDeck();
    renderDeck();
  }

  function showMatch(m) {
    body().innerHTML = `
      <div class="match-pop">
        <span class="heart-core big" aria-hidden="true">${heartSvg}</span>
        <h1 class="title">Deu match!</h1>
        <div class="match-pair"><img src="${esc(urls[me] || "")}" alt="Você"><img src="${esc(urls[m.user_id] || "")}" alt="${esc(m.nickname)}"></div>
        <p class="lead">Você e <b>${esc(m.nickname)}</b> se curtiram.${m.find_me ? ` Como achar: ${esc(m.find_me)}.` : ""}</p>
        <button class="cta heart-cta" type="button" id="hGoChat">Mandar uma mensagem</button>
        <button class="ghost" type="button" id="hKeep">Continuar conhecendo</button>
      </div>`;
    document.getElementById("hGoChat").addEventListener("click", () => openChat(m));
    document.getElementById("hKeep").addEventListener("click", () => { view = "conhecer"; renderDeck(); });
  }

  /* ---------- Matches e conversa ---------- */
  async function renderMatches() {
    await loadMatches();
    body().innerHTML = `
      ${tabs("matches")}
      ${matches.length ? matches.map(m => `
        <button type="button" class="match-row" data-m="${m.match_id}">
          <img src="${esc(urls[m.user_id] || "")}" alt="">
          <span><b>${esc(m.nickname)}</b>${m.find_me ? `<small>${esc(m.find_me)}</small>` : ""}</span>
          ${m.unread ? `<span class="dot-red" aria-label="Nova mensagem"></span>` : ""}
        </button>`).join("") : `<div class="empty">Nenhum match ainda. Continue curtindo em <b>Conhecer</b>.</div>`}`;
    wireTabs();
    body().querySelectorAll("[data-m]").forEach(b => b.addEventListener("click", () => openChat(matches.find(m => m.match_id === b.dataset.m))));
  }

  async function openChat(m) {
    chatMatch = m; view = "chat"; m.unread = false;
    const { data } = await sb.from("heart_messages").select("*").eq("match_id", m.match_id).order("created_at");
    chatMsgs = data || [];
    renderChat();
  }

  function renderChat() {
    const m = chatMatch;
    const last = chatMsgs[chatMsgs.length - 1];
    const canReply = last && last.from_user !== me && ASKS.includes(last.kind);
    const sentDrink = chatMsgs.some(x => x.from_user === me && x.kind === "drink");
    body().innerHTML = `
      <button type="button" class="back-link" id="hBack">← Matches</button>
      <div class="chat-head">
        <img src="${esc(urls[m.user_id] || "")}" alt="Foto de ${esc(m.nickname)}">
        <div><b>${esc(m.nickname)}</b>${m.find_me ? `<small>Como achar: ${esc(m.find_me)}</small>` : ""}</div>
      </div>
      <div class="chat">
        ${chatMsgs.length ? chatMsgs.map(x => `<div class="bubble ${x.from_user === me ? "mine" : ""}">${esc(MSG[x.kind])}</div>`).join("")
          : `<p class="hint" style="text-align:center">Vocês deram match. Que tal dar o primeiro passo?</p>`}
      </div>
      ${canReply ? `<div class="quick reply">
          <button type="button" class="q yes" data-k="sim">${MSG.sim}</button>
          <button type="button" class="q" data-k="nao">${MSG.nao}</button></div>` : ""}
      <div class="quick">
        ${ASKS.filter(k => !(k === "drink" && sentDrink)).map(k => `<button type="button" class="q" data-k="${k}">${MSG[k]}</button>`).join("")}
      </div>
      <div class="chat-foot">
        <button type="button" class="link-like" id="hBlock">Bloquear</button> ·
        <button type="button" class="link-like" id="hReport">Denunciar</button>
      </div>`;
    document.getElementById("hBack").addEventListener("click", () => { view = "matches"; chatMatch = null; render(); });
    body().querySelectorAll("[data-k]").forEach(b => b.addEventListener("click", () => send(b.dataset.k)));
    document.getElementById("hBlock").addEventListener("click", async () => {
      const { error } = await sb.rpc("heart_block", { p_event: ev().id, p_user: m.user_id, p_report: false, p_reason: "" });
      if (error) return toast(esc(errMsg(error)), true);
      toast(`Você bloqueou ${esc(m.nickname)}. Vocês não se veem mais nesta festa.`);
      view = "matches"; chatMatch = null; render();
    });
    document.getElementById("hReport").addEventListener("click", () => openReport(m.user_id, m.nickname, () => { view = "matches"; chatMatch = null; render(); }));
    const chat = body().querySelector(".chat"); chat.scrollTop = chat.scrollHeight;
  }

  async function send(kind) {
    body().querySelectorAll(".q").forEach(b => b.disabled = true);
    const { data, error } = await sb.rpc("heart_send", { p_match: chatMatch.match_id, p_kind: kind });
    if (error) { toast(esc(errMsg(error)), true); return renderChat(); }
    if (!chatMsgs.some(x => x.id === data.id)) chatMsgs.push(data);
    renderChat();
  }

  /* ---------- Denúncia ---------- */
  function openReport(uid, nickname, done) {
    const sheet = document.getElementById("sheet"), card = document.getElementById("sheetCard");
    card.innerHTML = `
      <h3>Denunciar ${esc(nickname)}</h3>
      <p class="lead" style="margin:4px 0 12px">Vocês deixam de se ver nesta festa. A organização recebe a denúncia.</p>
      <div class="chips" style="margin-bottom:14px">${REASONS.map(r => `<button type="button" class="chip-opt" data-r="${esc(r)}" aria-pressed="false">${esc(r)}</button>`).join("")}</div>
      <button class="cta" type="button" id="rSend" disabled>Enviar denúncia</button>
      <button class="ghost" type="button" id="rBlock">Só bloquear, sem denunciar</button>
      <button class="ghost" type="button" id="rCancel">Cancelar</button>`;
    sheet.hidden = false;
    let reason = "";
    card.querySelectorAll("[data-r]").forEach(b => b.addEventListener("click", () => {
      reason = b.dataset.r;
      card.querySelectorAll("[data-r]").forEach(x => x.setAttribute("aria-pressed", String(x === b)));
      document.getElementById("rSend").disabled = false;
    }));
    const go = async report => {
      const { error } = await sb.rpc("heart_block", { p_event: ev().id, p_user: uid, p_report: report, p_reason: report ? reason : "" });
      sheet.hidden = true;
      if (error) return toast(esc(errMsg(error)), true);
      toast(report ? "Denúncia enviada. Obrigado por avisar." : `Você bloqueou ${esc(nickname)}.`);
      done();
    };
    document.getElementById("rSend").addEventListener("click", () => go(true));
    document.getElementById("rBlock").addEventListener("click", () => go(false));
    document.getElementById("rCancel").addEventListener("click", () => { sheet.hidden = true; });
  }

  async function leave() {
    const btn = document.getElementById("hLeave");
    if (!btn.dataset.sure) { btn.dataset.sure = "1"; btn.textContent = "Toque de novo para sair e apagar seu perfil"; return; }
    const { error } = await sb.rpc("heart_leave", { p_event: ev().id });
    if (error) return toast(esc(errMsg(error)), true);
    await sb.storage.from(BUCKET).remove([photoPath(me)]);
    prof = null; coords = null; deck = []; matches = []; form.photo = null;
    toast("Você saiu do coração. Seu perfil e sua foto foram apagados.");
    render();
  }

  return { render, listen };
}
