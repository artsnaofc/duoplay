// ============================================================================
// Component: BottomNav — DuoPlay-Online
// Phase: Mobile-First Visual Polish & Native Touch Experience
// Description: Barra de navegação inferior nativa para celulares (320px–768px),
//              zona de alcance de polegar, touch targets >= 44px e safe area.
// ============================================================================

import React from 'react';
import { Gamepad2, Swords, Users, Trophy, User, LogIn, Play } from 'lucide-react';
import { useAuth } from '@/hooks/useAuth';
import { PlayerAvatar } from './profile/PlayerAvatar';

export interface BottomNavProps {
  onOpenHome?: () => void;
  onOpenMatchmaking?: () => void;
  onOpenFriends?: () => void;
  onOpenLeaderboard?: () => void;
  onOpenProfile?: () => void;
  onOpenAuth?: () => void;
  pendingFriendsCount?: number;
  hasActiveMatch?: boolean;
  onResumeActiveMatch?: () => void;
  activeMatchmakingCount?: number;
  currentSection?: 'home' | 'matchmaking' | 'friends' | 'leaderboard' | 'profile';
}

export const BottomNav: React.FC<BottomNavProps> = ({
  onOpenHome,
  onOpenMatchmaking,
  onOpenFriends,
  onOpenLeaderboard,
  onOpenProfile,
  onOpenAuth,
  pendingFriendsCount = 0,
  hasActiveMatch = false,
  onResumeActiveMatch,
  activeMatchmakingCount = 0,
  currentSection = 'home',
}) => {
  const { isAuthenticated, profile, user } = useAuth();

  const displayName =
    profile?.display_name ||
    user?.user_metadata?.display_name ||
    user?.email?.split('@')[0] ||
    'Eu';

  return (
    <nav
      aria-label="Navegação móvel principal"
      className="fixed bottom-0 inset-x-0 z-40 md:hidden bg-slate-950/92 backdrop-blur-xl border-t border-slate-800/90 shadow-[0_-8px_25px_rgba(0,0,0,0.5)] transition-all"
      style={{
        paddingBottom: 'max(0.6rem, env(safe-area-inset-bottom, 0px))',
      }}
    >
      <div className="grid grid-cols-5 items-center justify-around h-15 max-w-lg mx-auto px-1.5 pt-1.5">
        {/* 1. Início / Jogos */}
        <button
          type="button"
          onClick={onOpenHome}
          className={`flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 ${
            currentSection === 'home'
              ? 'text-blue-400 font-bold'
              : 'text-slate-400 hover:text-slate-200'
          }`}
          aria-label="Início e Catálogo de Jogos"
        >
          <div className="relative">
            <Gamepad2 className="w-5 h-5" />
          </div>
          <span className="text-[10px] mt-0.5 tracking-tight font-medium">Jogos</span>
        </button>

        {/* 2. Matchmaking / Partida Rápida / Partida Ativa */}
        {hasActiveMatch && onResumeActiveMatch ? (
          <button
            type="button"
            onClick={onResumeActiveMatch}
            className="flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 text-amber-300 font-bold animate-pulse"
            aria-label="Retornar à Partida Ativa"
          >
            <div className="relative flex items-center justify-center">
              <span className="absolute -top-1 -right-1 flex h-2.5 w-2.5">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-amber-400 opacity-75" />
                <span className="relative inline-flex rounded-full h-2.5 w-2.5 bg-amber-400" />
              </span>
              <Play className="w-5 h-5 fill-amber-400 text-amber-400" />
            </div>
            <span className="text-[10px] mt-0.5 tracking-tight font-bold">Em Jogo</span>
          </button>
        ) : (
          <button
            type="button"
            onClick={onOpenMatchmaking}
            className={`flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 ${
              activeMatchmakingCount > 0
                ? 'text-indigo-300 font-bold'
                : 'text-slate-400 hover:text-slate-200'
            }`}
            aria-label="Buscar Partida"
          >
            <div className="relative">
              {activeMatchmakingCount > 0 && (
                <span className="absolute -top-1 -right-1 flex h-2.5 w-2.5">
                  <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-indigo-400 opacity-75" />
                  <span className="relative inline-flex rounded-full h-2.5 w-2.5 bg-indigo-400" />
                </span>
              )}
              <Swords className="w-5 h-5" />
            </div>
            <span className="text-[10px] mt-0.5 tracking-tight font-medium">
              {activeMatchmakingCount > 0 ? 'Buscando' : 'Partidas'}
            </span>
          </button>
        )}

        {/* 3. Amigos / Social */}
        <button
          type="button"
          onClick={isAuthenticated ? onOpenFriends : onOpenAuth}
          className="flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 text-slate-400 hover:text-slate-200"
          aria-label="Comunidade de Amigos"
        >
          <div className="relative">
            <Users className="w-5 h-5" />
            {pendingFriendsCount > 0 && (
              <span className="absolute -top-1.5 -right-2 px-1.5 py-0.2 rounded-full bg-red-600 text-[9px] font-black text-white ring-2 ring-slate-950 animate-bounce">
                {pendingFriendsCount}
              </span>
            )}
          </div>
          <span className="text-[10px] mt-0.5 tracking-tight font-medium">Amigos</span>
        </button>

        {/* 4. Ranking / Leaderboard */}
        <button
          type="button"
          onClick={onOpenLeaderboard}
          className="flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 text-slate-400 hover:text-amber-300"
          aria-label="Classificação e Ranking Geral"
        >
          <div className="relative">
            <Trophy className="w-5 h-5 text-amber-400/90" />
          </div>
          <span className="text-[10px] mt-0.5 tracking-tight font-medium">Ranking</span>
        </button>

        {/* 5. Perfil / Login */}
        {isAuthenticated ? (
          <button
            type="button"
            onClick={onOpenProfile}
            className="flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 text-slate-400 hover:text-purple-300"
            aria-label="Meu Perfil de Jogador"
          >
            <div className="relative flex items-center justify-center">
              <PlayerAvatar
                avatarUrl={profile?.avatar_url}
                displayName={displayName}
                username={profile?.username}
                size="xs"
              />
            </div>
            <span className="text-[10px] mt-0.5 tracking-tight font-medium truncate max-w-[46px]">
              Perfil
            </span>
          </button>
        ) : (
          <button
            type="button"
            onClick={onOpenAuth}
            className="flex flex-col items-center justify-center min-h-[44px] min-w-[44px] rounded-xl transition-all active:scale-95 text-blue-400 font-semibold"
            aria-label="Entrar na Conta"
          >
            <div className="relative">
              <LogIn className="w-5 h-5" />
            </div>
            <span className="text-[10px] mt-0.5 tracking-tight">Entrar</span>
          </button>
        )}
      </div>
    </nav>
  );
};
