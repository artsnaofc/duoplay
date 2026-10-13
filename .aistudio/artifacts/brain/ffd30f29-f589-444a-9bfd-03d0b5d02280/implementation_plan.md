# Plano de Implementação — Desativação de Zoom, Otimização Mobile e Redesign do Carta Duo

## 1. Visão Geral
Este plano aborda três objetivos principais solicitados:
1. **Desativação de Zoom no Aplicativo**: Configurar a tag `meta name="viewport"` para impedir pinças de zoom, duplo toque e escala manual (`user-scalable=no`, `maximum-scale=1.0`), garantindo comportamento nativo de aplicativo móvel.
2. **Melhoria da Responsividade Mobile**: Otimizar padding, margens, tamanhos de toque (mínimo 44px) e flexibilidade de containers em todas as telas principais e modais.
3. **Redesign Completo do Carta Duo**: Redesenhar a interface do jogo Carta Duo (`CartaDuoGame.tsx` e componentes relacionados), criando um baralho visualmente impressionante com cartas estilizadas (cores vibrantes para vermelho, azul, verde, amarelo e curingas com gradientes e símbolos nítidos), tabuleiro de descarte imersivo e rack de cartas do jogador otimizado para polegar com rolagem horizontal fluida e animações de jogada.

---

## 2. Mudanças Propostas

### A. Desativação de Zoom e Ajustes de Viewport
- **`index.html`**: Atualizar a tag viewport para:
  `content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover"`
- **`src/index.css`**: Adicionar regras CSS globais de toque (`touch-action: manipulation; -webkit-user-select: none; user-select: none;`).

### B. Redesign Completo do Carta Duo (`src/games/carta-duo/`)
- **Cartas (`CartaDuoCard.tsx` ou componente interno)**:
  - Estética gamer arcade premium com bordas arredondadas elegantes, sombras profundas, gradientes ricos por cor (Vermelho Ruby, Azul Cobalt, Verde Emerald, Amarelo Amber e Curingas Arco-Íris).
  - Símbolos e números grandes e legíveis com ícones nítidos para bloqueio, inversão, +2 e +4.
- **Tabuleiro / Área de Descarte & Mesa**:
  - Exibição imersiva da carta atual no topo da pilha de descarte com efeito de brilho e reflexo.
  - Indicador claro da cor ativa quando um curinga é jogado.
  - Painel de status dos oponentes com avatares, contagem de cartas na mão e indicador de turno ativo.
- **Baralho & Mão do Jogador (Rack)**:
  - Rolagem horizontal fluida (`overflow-x-auto snap-x scrollbar-none`) com cartas escaladas perfeitamente para visualização em telas de 320px em diante.
  - Botões de ação rápida ("Comprar Carta", "Dizer DUO!").
  - Modal/Seletor de Cor Curinga redesenhado com botões circulares grandes e coloridos para fácil toque.

---

## 3. Plano de Verificação
1. **Compilação**: Executar `compile_applet` para validar ausência de erros TypeScript ou de JSX.
2. **Inspeção de Código**: Verificar se as alterações cobrem `index.html`, `src/index.css` e os componentes do `carta-duo`.
3. **Testes Visuais e Funcionais**: Testar a interatividade do Carta Duo, compra de cartas, jogadas válidas e seleção de cor curinga.
