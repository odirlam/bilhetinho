// Bilhetinho · código comum a todas as telas.
// supabase-js 2.45.4 e qrcode-generator 1.4.4 ficam em assets/vendor (carregados pela página).
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "../config.js";

export const configured = !SUPABASE_URL.includes("COLE_AQUI") && !SUPABASE_ANON_KEY.includes("COLE_AQUI");
export const sb = configured ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;

// Garante uma sessão. Plateia e tablet usam login anônimo (sem cadastro).
export async function ensureSession() {
  const { data: { session } } = await sb.auth.getSession();
  if (session) return session;
  const { data, error } = await sb.auth.signInAnonymously();
  if (error) throw error;
  return data.session;
}

export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export const norm = s => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
export const brl = n => "R$ " + Number(n || 0).toLocaleString("pt-BR");
// Valor com centavos: R$ 5,50.
export const money = n => "R$ " + Number(n || 0).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

// Modelo de receita decidido em 19/11/2026 (Pix ainda simulado):
// gorjeta, destaque e prioridade: a plateia paga o Pix + taxa de serviço e a banda recebe 100%;
// fura-fila: o preço é o da banda e o app fica com uma comissão sobre ele.
export const SERVICE_FEE = 0.10;
export const FF_COMMISSION = 0.20;
// Quanto a pessoa paga e quanto a banda recebe por um Pix.
export const pixSplit = (tip, ff) => ff
  ? { paga: tip, banda: tip * (1 - FF_COMMISSION) }
  : { paga: tip * (1 + SERVICE_FEE), banda: tip };
export const ago = t => { const m = Math.round((Date.now() - new Date(t)) / 60000); return m < 1 ? "agora" : m < 60 ? "há " + m + " min" : "há " + Math.floor(m / 60) + " h"; };
export const fmtDay = d => new Date(d).toLocaleDateString("pt-BR", { weekday: "short", day: "2-digit", month: "2-digit" });
// 850 -> "850 m"; 2300 -> "2,3 km"
export const fmtDist = m => m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km`;
export const fmtTime = d => new Date(d).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });

export const MODE_NAME = { destaque: "Pix só destaca", prioridade: "Pix dá prioridade", furafila: "Fura-fila" };
export const STATUS_TXT = { fila: "Na fila", tocando: "Tocando agora", tocada: "Tocada", nao: "Fora do repertório" };

// Janela em que o evento aceita pedidos (igual à regra do banco).
export function eventWindow(ev) {
  const now = Date.now(), s = new Date(ev.starts_at).getTime(), e = new Date(ev.ends_at).getTime();
  if (now < s - 3 * 3600e3) return "antes";
  if (now > e + 3600e3) return "depois";
  return "aberto";
}

// Mensagens de erro em português para os códigos do banco.
const ERRORS = {
  evento_fechado: "Este evento não está aceitando pedidos agora.",
  evento_nao_encontrado: "Evento não encontrado.",
  muitos_pedidos: "Calma! Você fez muitos pedidos seguidos. Tente de novo em alguns minutos.",
  furafila_esgotado: "O fura-fila esgotou nesta hora. Escolha outra opção.",
  valor_invalido: "Valor de Pix inválido.",
  pedido_fechado: "Este pedido não está mais na fila.",
  sem_permissao: "Você não tem permissão para isso.",
  precisa_login: "Você precisa entrar com seu e-mail.",
  sem_banda: "Cadastre o nome da banda primeiro.",
  longe_da_festa: "Parece que você não está no local da festa.",
  menor_de_idade: "O coração é só para maiores de 18 anos.",
  local_nao_definido: "O coração ainda não foi ativado nesta festa.",
  removido: "Seu perfil foi removido desta festa.",
  sem_perfil: "Entre no coração primeiro.",
  perfil_indisponivel: "Essa pessoa não está mais disponível.",
  calma: "Calma! Espere um pouquinho antes de mandar de novo.",
  drink_ja_enviado: "Você já convidou essa pessoa para um drink.",
  limite_drinks: "Você já mandou os 5 convites de drink desta noite.",
  nada_para_responder: "Ainda não há nada para responder.",
  mesa_invalida: "Informe sua mesa na aba Você para mandar essa resposta.",
  sem_como_achar: "Preencha o \"como te achar\" no seu perfil do coração.",
  pedido_invalido: "Não encontramos esse pedido de música.",
  local_invalido: "Não deu para registrar o local da festa.",
  codigo_expirado: "O código do tablet expirou. Escaneie o QR novo que aparece no tablet."
};
export function errMsg(e) {
  const m = (e && (e.message || e.error_description)) || String(e);
  for (const k in ERRORS) if (m.includes(k)) return ERRORS[k];
  if (/fetch|network/i.test(m)) return "Sem conexão. Confira a internet e tente de novo.";
  return "Algo deu errado: " + m;
}

// QR code (biblioteca qrcode-generator carregada na página).
export function qrDataUrl(text, cell = 6) {
  const q = window.qrcode(0, "M");
  q.addData(text);
  q.make();
  return q.createDataURL(cell, 2);
}

let toastTimer;
export function toast(html, isErr = false) {
  let el = document.getElementById("toast");
  if (!el) { el = document.createElement("div"); el.id = "toast"; el.className = "toast"; el.setAttribute("role", "status"); document.body.appendChild(el); }
  el.innerHTML = html;
  el.classList.toggle("err", isErr);
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 4200);
}

export function store(k, v) {
  try { if (v === undefined) return JSON.parse(localStorage.getItem("bh_" + k)); localStorage.setItem("bh_" + k, JSON.stringify(v)); } catch (_) { return null; }
}

export function notConfigured(el) {
  el.innerHTML = `<div class="center"><div class="logo">Bilhetinho</div><p>O app ainda não foi ligado ao banco de dados. Preencha o arquivo <b>config.js</b> com os dados do Supabase.</p></div>`;
}

export const voteIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>`;

// Ordem da fila no palco: fura-fila pago no topo; depois votos (+2 se a regra
// do pedido era "prioridade" e o Pix foi pago) ou ordem de chegada.
export function sortQueue(list, by = "votos") {
  const isFF = r => r.ff && r.tip_status === "paid";
  const score = r => r.votes + (r.tip_status === "paid" && r.mode === "prioridade" ? 2 : 0);
  return list.slice().sort((a, b) => {
    const f = isFF(b) - isFF(a);
    if (f) return f;
    const t = new Date(a.created_at) - new Date(b.created_at);
    if (isFF(a) && isFF(b)) return t;
    return by === "votos" ? (score(b) - score(a) || t) : t;
  });
}

// Lista de sugestões (cerca de 50 clássicos flashback). A banda poderá ter o
// próprio repertório numa próxima versão.
export const CATALOG = [
  ["Menina Veneno","Ritchie"],["A Vida Tem Dessas Coisas","Ritchie"],["Eva","Rádio Táxi"],["Você Não Soube Me Amar","Blitz"],
  ["Como uma Onda","Lulu Santos"],["Tempos Modernos","Lulu Santos"],["Como Eu Quero","Kid Abelha"],["Fixação","Kid Abelha"],
  ["Olhar 43","RPM"],["Rádio Pirata","RPM"],["Tempo Perdido","Legião Urbana"],["Será","Legião Urbana"],["Sonífera Ilha","Titãs"],
  ["Óculos","Os Paralamas do Sucesso"],["Meu Erro","Os Paralamas do Sucesso"],["Pro Dia Nascer Feliz","Barão Vermelho"],
  ["Inútil","Ultraje a Rigor"],["Fullgás","Marina Lima"],["Tédio","Biquini Cavadão"],["Infinita Highway","Engenheiros do Hawaii"],
  ["Música Urbana","Capital Inicial"],["Whisky a Go-Go","Roupa Nova"],["Serão Extra","Dr. Silvana & Cia"],["Beat Acelerado","Metrô"],
  ["Do Leme ao Pontal","Tim Maia"],["Billie Jean","Michael Jackson"],["Take On Me","a-ha"],["Like a Virgin","Madonna"],
  ["Girls Just Want to Have Fun","Cyndi Lauper"],["Livin' on a Prayer","Bon Jovi"],["I Want to Break Free","Queen"],
  ["Hungry Like the Wolf","Duran Duran"],["Everybody Wants to Rule the World","Tears for Fears"],
  ["I Wanna Dance with Somebody","Whitney Houston"],["Never Gonna Give You Up","Rick Astley"],["The Final Countdown","Europe"],
  ["Africa","Toto"],["Stayin' Alive","Bee Gees"],["Dancing Queen","ABBA"],["I Will Survive","Gloria Gaynor"],
  ["Every Breath You Take","The Police"],["Don't You (Forget About Me)","Simple Minds"],["Another Day in Paradise","Phil Collins"],
  ["All Night Long","Lionel Richie"],["Celebration","Kool & The Gang"],["West End Girls","Pet Shop Boys"],
  ["What's on Your Mind","Information Society"],["Please Don't Go","Double You"],["The Rhythm of the Night","Corona"],["It's My Life","Dr. Alban"]
];
