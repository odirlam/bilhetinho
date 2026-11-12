# Bilhetinho

Pedidos de música digitais para festas, bares e shows. A plateia pede pelo celular (com dedicatória e Pix opcional) e a banda vê tudo legível no tablet do palco.

**Versão de teste.** O Pix é simulado: nenhum pagamento de verdade acontece.

## Telas

| Endereço | Quem usa | O que faz |
| --- | --- | --- |
| `/e/<evento>` | Plateia (pelo QR code) | Pedir música, votar na fila, acompanhar os próprios pedidos |
| `/palco` | Tablet do palco | Fila ao vivo, "Vou tocar / Não tenho / Tocada", regra do Pix |
| `/banda` | Banda ou organizador | Login por e-mail, criar evento, QR da plateia, conectar o tablet |
| `/` | Todos | Página inicial |

## Como está montado

- Site estático (HTML, CSS e JavaScript, sem etapa de build), publicado na Vercel.
- Banco de dados, login e tempo real no Supabase. O esquema completo está em `supabase/schema.sql`.
- A plateia e o tablet entram com login anônimo do Supabase. A banda entra com link mágico por e-mail.
- Ninguém escreve direto nas tabelas: toda escrita passa por funções do banco que conferem as regras (música repetida vira voto, limite do fura-fila, só a banda ou o tablet pareado mexem no palco).
- Bibliotecas em `assets/vendor`: supabase-js 2.45.4 e qrcode-generator 1.4.4.

## Configuração

1. No Supabase, rode `supabase/schema.sql` no SQL Editor.
2. Em Authentication > Sign In / Providers, ligue **Allow anonymous sign-ins**.
3. Em Authentication > URL Configuration, coloque o endereço do site em **Site URL** e acrescente `https://<seu-site>/banda` em **Redirect URLs**.
4. Preencha `config.js` com a Project URL e a chave `anon public` (Project Settings > API).
