// ============================================================================
// Page: FriendsPage — DuoPlay-Online
// Phase: Transformação de Modais em Páginas Dedicadas & Redesign Social
// Description: Página completa e mobile-first da Central de Amigos, com abas
//              de Amigos, Solicitações e Busca em tempo real, visual gamer premium,
//              estatísticas sociais, touch targets >= 44px e responsividade total.
// ============================================================================

import React, { useState, useEffect, useRef, useMemo } from 'react';
import {
  Users,
  UserPlus,
  Search,
  RefreshCw,
  Check,
  UserCheck,
  UserX,
  Play,
  Gamepad2,
  AlertCircle,
  Clock,
  Trash2,
  LogIn,
  MessageSquare,
  ArrowLeft,
  Swords,
  Sparkles,
  Shield,
  ExternalLink,
  X,
  ChevronRight,
} from 'lucide-react';
import { PlayerAvatar } from '@/components/profile/PlayerAvatar';
import { useSocial } from '@/hooks/useSocial';
import { useAuth } from '@/hooks/useAuth';
import { searchPlayers } from '@/services/social';
import type { Friend, FriendSearchResult } from '@/types/social';

export interface FriendsPageProps {
  onNavigateHome: () => void;
  onViewUserProfile?: (userId: string) => void;
  onPlayWithFriend?: (friend: Friend) => void;
  onOpenChatWithFriend?: (friendUserId: string) => void;
  onOpenAuth?: () => void;
  initialTab?: 'friends' | 'requests' | 'search';
}

export const FriendsPage: React.FC<FriendsPageProps> = ({
  onNavigateHome,
  onViewUserProfile,
  onPlayWithFriend,
  onOpenChatWithFriend,
  onOpenAuth,
  initialTab = 'friends',
}) => {
  const { isAuthenticated, isLoading: isAuthLoading } = useAuth();
  const [activeTab, setActiveTab] = useState<'friends' | 'requests' | 'search'>(initialTab);
  const [friendFilter, setFriendFilter] = useState('');
  const [onlineOnly, setOnlineOnly] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<FriendSearchResult[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [actionLoadingId, setActionLoadingId] = useState<string | null>(null);
  const [confirmRemoveFriendId, setConfirmRemoveFriendId] = useState<string | null>(null);

  const {
    friends,
    receivedRequests,
    sentRequests,
    pendingCount,
    isLoading: isSocialLoading,
    error: socialError,
    refresh,
    sendRequest,
    acceptRequest,
    declineRequest,
    cancelRequest,
    removeFriendship,
  } = useSocial();

  const searchDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Recarrega lista social ao montar ou autenticar
  useEffect(() => {
    if (isAuthenticated) {
      refresh(true);
    }
  }, [isAuthenticated, refresh]);

  // Busca de novos jogadores com debounce de 300ms
  useEffect(() => {
    if (activeTab !== 'search') return;

    const trimmed = searchQuery.trim().replace(/^@/, '');
    if (trimmed.length < 2) {
      setSearchResults([]);
      setIsSearching(false);
      setSearchError(null);
      return;
    }

    if (searchDebounceRef.current) {
      clearTimeout(searchDebounceRef.current);
    }

    setIsSearching(true);
    setSearchError(null);

    searchDebounceRef.current = setTimeout(async () => {
      const res = await searchPlayers(trimmed);
      setIsSearching(false);
      if (res.success && res.data) {
        setSearchResults(res.data);
      } else {
        setSearchError(res.error || 'Erro ao buscar jogadores.');
      }
    }, 300);

    return () => {
      if (searchDebounceRef.current) {
        clearTimeout(searchDebounceRef.current);
      }
    };
  }, [searchQuery, activeTab]);

  // Contadores e estatísticas rápidas
  const onlineFriends = useMemo(
    () => friends.filter((f) => f.online_status === 'online' || f.online_status === 'in_game'),
    [friends]
  );

  const filteredFriends = useMemo(() => {
    return friends.filter((f) => {
      if (onlineOnly && f.online_status !== 'online' && f.online_status !== 'in_game') {
        return false;
      }
      if (!friendFilter.trim()) return true;
      const q = friendFilter.toLowerCase().trim();
      return (
        f.display_name.toLowerCase().includes(q) ||
        f.username.toLowerCase().includes(q)
      );
    });
  }, [friends, friendFilter, onlineOnly]);

  // Ações sociais com feedback de loading individual
  const handleSendRequest = async (targetUserId: string) => {
    setActionLoadingId(targetUserId);
    try {
      await sendRequest(targetUserId);
      setSearchResults((prev) =>
        prev.map((r) =>
          r.user_id === targetUserId
            ? { ...r, friendship_status: 'pending_sent' }
            : r
        )
      );
    } finally {
      setActionLoadingId(null);
    }
  };

  const handleAccept = async (requestId: string) => {
    setActionLoadingId(requestId);
    try {
      await acceptRequest(requestId);
    } finally {
      setActionLoadingId(null);
    }
  };

  const handleDecline = async (requestId: string) => {
    setActionLoadingId(requestId);
    try {
      await declineRequest(requestId);
    } finally {
      setActionLoadingId(null);
    }
  };

  const handleCancel = async (requestId: string) => {
    setActionLoadingId(requestId);
    try {
      await cancelRequest(requestId);
    } finally {
      setActionLoadingId(null);
    }
  };

  const handleRemoveFriend = async (friendshipId: string) => {
    setActionLoadingId(friendshipId);
    try {
      await removeFriendship(friendshipId);
      setConfirmRemoveFriendId(null);
    } finally {
      setActionLoadingId(null);
    }
  };

  return (
    <div className="min-h-screen pb-24 md:pb-16 text-slate-100">
      {/* Top Header Bar & Breadcrumb */}
      <div className="border-b border-slate-800/80 bg-slate-950/70 backdrop-blur-md sticky top-16 z-20">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 py-4 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={onNavigateHome}
              className="inline-flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 hover:bg-slate-800 text-slate-300 hover:text-white text-xs font-bold transition-all active:scale-95 shadow-sm"
              aria-label="Voltar aos Jogos"
            >
              <ArrowLeft className="w-4 h-4 text-blue-400" />
              <span>Voltar aos Jogos</span>
            </button>
            <div className="h-5 w-px bg-slate-800 hidden sm:block" />
            <div>
              <div className="flex items-center gap-2">
                <div className="w-7 h-7 rounded-lg bg-indigo-500/20 border border-indigo-500/30 flex items-center justify-center text-indigo-400">
                  <Users className="w-4 h-4" />
                </div>
                <h1 className="text-lg sm:text-xl font-black text-white tracking-tight">
                  Central de Amigos
                </h1>
              </div>
              <p className="text-xs text-slate-400 mt-0.5">
                Conecte-se, acompanhe status em tempo real e convide para duelos
              </p>
            </div>
          </div>

          {/* Quick Actions */}
          {isAuthenticated && (
            <div className="flex items-center gap-2 self-start sm:self-auto">
              <button
                type="button"
                onClick={() => refresh(true)}
                disabled={isSocialLoading}
                className="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 border border-slate-800 text-xs font-semibold text-slate-300 hover:text-white transition-all disabled:opacity-50"
                title="Atualizar lista"
              >
                <RefreshCw className={`w-3.5 h-3.5 ${isSocialLoading ? 'animate-spin text-blue-400' : ''}`} />
                <span className="hidden sm:inline">Atualizar</span>
              </button>
              <button
                type="button"
                onClick={() => setActiveTab('search')}
                className="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white text-xs font-bold shadow-md shadow-blue-900/40 transition-all active:scale-95"
              >
                <UserPlus className="w-3.5 h-3.5" />
                <span>Adicionar Amigos</span>
              </button>
            </div>
          )}
        </div>
      </div>

      <div className="max-w-6xl mx-auto px-4 sm:px-6 py-6 sm:py-8 space-y-6">
        {/* Caso não autenticado */}
        {!isAuthenticated && !isAuthLoading && (
          <div className="p-8 sm:p-12 rounded-3xl bg-gradient-to-br from-slate-900 via-indigo-950/20 to-slate-900 border border-indigo-900/40 text-center max-w-xl mx-auto shadow-2xl space-y-5">
            <div className="w-16 h-16 rounded-2xl bg-indigo-600/20 border border-indigo-500/40 flex items-center justify-center text-indigo-400 mx-auto shadow-inner">
              <Users className="w-8 h-8" />
            </div>
            <div className="space-y-2">
              <h2 className="text-xl sm:text-2xl font-black text-white">
                Crie sua Rede de Rivais e Parceiros
              </h2>
              <p className="text-xs sm:text-sm text-slate-400 max-w-md mx-auto leading-relaxed">
                Faça login para adicionar amigos, ver quem está online, trocar mensagens e iniciar salas multiplayer com 1 clique.
              </p>
            </div>
            {onOpenAuth && (
              <button
                type="button"
                onClick={onOpenAuth}
                className="inline-flex items-center gap-2 px-6 py-3 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white font-bold text-sm shadow-xl shadow-blue-950/50 transition-all active:scale-95"
              >
                <LogIn className="w-4 h-4" />
                <span>Entrar ou Criar Conta</span>
              </button>
            )}
          </div>
        )}

        {/* Usuário Autenticado */}
        {isAuthenticated && (
          <>
            {/* Quick Metrics Bar */}
            <div className="grid grid-cols-3 gap-3 sm:gap-4">
              <div className="p-4 rounded-2xl bg-slate-900/80 border border-slate-800/80 flex items-center gap-3.5">
                <div className="w-11 h-11 rounded-xl bg-blue-600/10 border border-blue-500/20 flex items-center justify-center text-blue-400 shrink-0">
                  <Users className="w-5 h-5" />
                </div>
                <div>
                  <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider block">
                    Total de Amigos
                  </span>
                  <span className="text-xl sm:text-2xl font-black text-white">
                    {friends.length}
                  </span>
                </div>
              </div>

              <div className="p-4 rounded-2xl bg-slate-900/80 border border-slate-800/80 flex items-center gap-3.5">
                <div className="w-11 h-11 rounded-xl bg-emerald-600/10 border border-emerald-500/20 flex items-center justify-center text-emerald-400 shrink-0">
                  <span className="relative flex h-3 w-3">
                    <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75" />
                    <span className="relative inline-flex rounded-full h-3 w-3 bg-emerald-500" />
                  </span>
                </div>
                <div>
                  <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider block">
                    Online Agora
                  </span>
                  <span className="text-xl sm:text-2xl font-black text-emerald-400">
                    {onlineFriends.length}
                  </span>
                </div>
              </div>

              <div
                onClick={() => setActiveTab('requests')}
                className={`p-4 rounded-2xl border transition-all cursor-pointer flex items-center gap-3.5 ${
                  pendingCount > 0
                    ? 'bg-amber-950/20 border-amber-500/40 hover:border-amber-400'
                    : 'bg-slate-900/80 border-slate-800/80 hover:border-slate-700'
                }`}
              >
                <div className={`w-11 h-11 rounded-xl flex items-center justify-center shrink-0 ${
                  pendingCount > 0
                    ? 'bg-amber-500/20 border border-amber-500/40 text-amber-400'
                    : 'bg-slate-800 border border-slate-700 text-slate-400'
                }`}>
                  <UserPlus className="w-5 h-5" />
                </div>
                <div>
                  <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider block">
                    Solicitações
                  </span>
                  <div className="flex items-center gap-1.5">
                    <span className={`text-xl sm:text-2xl font-black ${pendingCount > 0 ? 'text-amber-400' : 'text-white'}`}>
                      {pendingCount}
                    </span>
                    {pendingCount > 0 && (
                      <span className="px-1.5 py-0.5 rounded text-[10px] font-extrabold bg-amber-500/20 text-amber-300 border border-amber-500/30">
                        Novo
                      </span>
                    )}
                  </div>
                </div>
              </div>
            </div>

            {/* Tab Navigation Segment Control */}
            <div className="flex p-1.5 bg-slate-900/90 rounded-2xl border border-slate-800/90 max-w-lg">
              <button
                type="button"
                onClick={() => setActiveTab('friends')}
                className={`flex-1 flex items-center justify-center gap-2 py-2.5 px-3 rounded-xl text-xs sm:text-sm font-bold transition-all ${
                  activeTab === 'friends'
                    ? 'bg-gradient-to-r from-blue-600 to-indigo-600 text-white shadow-md shadow-blue-950/50'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                <Users className="w-4 h-4" />
                <span>Meus Amigos</span>
                <span className={`text-[11px] px-1.5 py-0.2 rounded-md font-extrabold ${
                  activeTab === 'friends' ? 'bg-white/20 text-white' : 'bg-slate-800 text-slate-400'
                }`}>
                  {friends.length}
                </span>
              </button>

              <button
                type="button"
                onClick={() => setActiveTab('requests')}
                className={`flex-1 flex items-center justify-center gap-2 py-2.5 px-3 rounded-xl text-xs sm:text-sm font-bold transition-all relative ${
                  activeTab === 'requests'
                    ? 'bg-gradient-to-r from-blue-600 to-indigo-600 text-white shadow-md shadow-blue-950/50'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                <UserCheck className="w-4 h-4" />
                <span>Solicitações</span>
                {pendingCount > 0 && (
                  <span className="px-1.5 py-0.2 rounded-full text-[10px] font-extrabold bg-red-500 text-white animate-pulse">
                    {pendingCount}
                  </span>
                )}
              </button>

              <button
                type="button"
                onClick={() => setActiveTab('search')}
                className={`flex-1 flex items-center justify-center gap-2 py-2.5 px-3 rounded-xl text-xs sm:text-sm font-bold transition-all ${
                  activeTab === 'search'
                    ? 'bg-gradient-to-r from-blue-600 to-indigo-600 text-white shadow-md shadow-blue-950/50'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                <Search className="w-4 h-4" />
                <span>Buscar</span>
              </button>
            </div>

            {/* TAB 1: MEUS AMIGOS */}
            {activeTab === 'friends' && (
              <div className="space-y-4 animate-fade-in">
                {/* Search & Filter Toolbar */}
                {friends.length > 0 && (
                  <div className="flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-3 p-3 rounded-2xl bg-slate-900/60 border border-slate-800/80">
                    <div className="relative flex-1">
                      <Search className="w-4 h-4 absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-400" />
                      <input
                        type="text"
                        value={friendFilter}
                        onChange={(e) => setFriendFilter(e.target.value)}
                        placeholder="Filtrar por nome ou @username..."
                        className="w-full pl-10 pr-9 py-2 rounded-xl bg-slate-950 border border-slate-800 text-xs sm:text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:border-blue-500 transition-colors"
                      />
                      {friendFilter && (
                        <button
                          type="button"
                          onClick={() => setFriendFilter('')}
                          className="absolute right-3 top-1/2 -translate-y-1/2 p-1 text-slate-400 hover:text-white"
                        >
                          <X className="w-3.5 h-3.5" />
                        </button>
                      )}
                    </div>

                    <button
                      type="button"
                      onClick={() => setOnlineOnly(!onlineOnly)}
                      className={`inline-flex items-center gap-2 px-3 py-2 rounded-xl text-xs font-bold border transition-all ${
                        onlineOnly
                          ? 'bg-emerald-950/60 border-emerald-600 text-emerald-300'
                          : 'bg-slate-950 border-slate-800 text-slate-400 hover:text-slate-200'
                      }`}
                    >
                      <span className={`w-2 h-2 rounded-full ${onlineOnly ? 'bg-emerald-400' : 'bg-slate-600'}`} />
                      <span>Apenas Online ({onlineFriends.length})</span>
                    </button>
                  </div>
                )}

                {/* Lista / Grid de Amigos */}
                {filteredFriends.length === 0 ? (
                  <div className="p-12 rounded-3xl bg-slate-900/40 border border-slate-800/80 text-center space-y-4">
                    <div className="w-14 h-14 rounded-2xl bg-slate-800/60 border border-slate-700/60 flex items-center justify-center text-slate-500 mx-auto">
                      <Users className="w-7 h-7" />
                    </div>
                    <div className="space-y-1">
                      <h3 className="text-base font-bold text-white">
                        {friends.length === 0 ? 'Nenhum amigo adicionado ainda' : 'Nenhum amigo encontrado no filtro'}
                      </h3>
                      <p className="text-xs text-slate-400 max-w-sm mx-auto">
                        {friends.length === 0
                          ? 'Encontre outros competidores pelo nome de usuário e comece a jogar juntos!'
                          : 'Tente alterar os termos da busca para encontrar seu amigo.'}
                      </p>
                    </div>
                    {friends.length === 0 && (
                      <button
                        type="button"
                        onClick={() => setActiveTab('search')}
                        className="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-xs font-bold transition-all shadow-md active:scale-95"
                      >
                        <UserPlus className="w-4 h-4" />
                        <span>Buscar Jogadores</span>
                      </button>
                    )}
                  </div>
                ) : (
                  <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
                    {filteredFriends.map((friend) => {
                      const isOnline = friend.online_status === 'online';
                      const isInGame = friend.online_status === 'in_game';
                      const isRemoving = confirmRemoveFriendId === friend.friendship_id;

                      return (
                        <div
                          key={friend.friendship_id}
                          className="p-4 rounded-2xl bg-slate-900/90 border border-slate-800/90 hover:border-slate-700/80 transition-all flex flex-col justify-between gap-4 shadow-sm group"
                        >
                          {/* Top Info */}
                          <div className="flex items-start justify-between gap-3">
                            <div
                              onClick={() => onViewUserProfile?.(friend.user_id)}
                              className="flex items-center gap-3 cursor-pointer select-none min-w-0"
                            >
                              <div className="relative shrink-0">
                                <PlayerAvatar
                                  avatarUrl={friend.avatar_url}
                                  displayName={friend.display_name}
                                  size="md"
                                />
                                <span
                                  className={`absolute -bottom-0.5 -right-0.5 w-3.5 h-3.5 rounded-full border-2 border-slate-900 ${
                                    isInGame
                                      ? 'bg-blue-400 ring-2 ring-blue-500/40 animate-pulse'
                                      : isOnline
                                      ? 'bg-emerald-500 ring-2 ring-emerald-500/40'
                                      : 'bg-slate-600'
                                  }`}
                                  title={isInGame ? 'Em Partida' : isOnline ? 'Online' : 'Offline'}
                                />
                              </div>

                              <div className="min-w-0">
                                <h4 className="text-sm font-bold text-white truncate group-hover:text-blue-300 transition-colors">
                                  {friend.display_name}
                                </h4>
                                <span className="text-xs text-slate-400 truncate block">
                                  @{friend.username}
                                </span>
                                <div className="flex items-center gap-1.5 mt-1">
                                  <span
                                    className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[10px] font-bold ${
                                      isInGame
                                        ? 'bg-blue-950/70 border border-blue-500/40 text-blue-300'
                                        : isOnline
                                        ? 'bg-emerald-950/70 border border-emerald-500/40 text-emerald-300'
                                        : 'bg-slate-800/70 border border-slate-700/50 text-slate-400'
                                    }`}
                                  >
                                    <span
                                      className={`w-1.5 h-1.5 rounded-full ${
                                        isInGame ? 'bg-blue-400' : isOnline ? 'bg-emerald-400' : 'bg-slate-500'
                                      }`}
                                    />
                                    <span>{isInGame ? 'Jogando' : isOnline ? 'Online' : 'Offline'}</span>
                                  </span>
                                </div>
                              </div>
                            </div>

                            <button
                              type="button"
                              onClick={() => onViewUserProfile?.(friend.user_id)}
                              className="p-1.5 text-slate-500 hover:text-slate-300 rounded-lg hover:bg-slate-800 transition-colors shrink-0"
                              title="Ver perfil completo"
                            >
                              <ExternalLink className="w-4 h-4" />
                            </button>
                          </div>

                          {/* Action Buttons */}
                          {isRemoving ? (
                            <div className="p-3 rounded-xl bg-red-950/50 border border-red-800/60 space-y-2 animate-fade-in">
                              <span className="text-[11px] text-red-200 font-semibold block">
                                Remover {friend.display_name} dos amigos?
                              </span>
                              <div className="flex items-center gap-2">
                                <button
                                  type="button"
                                  onClick={() => handleRemoveFriend(friend.friendship_id)}
                                  disabled={actionLoadingId === friend.friendship_id}
                                  className="flex-1 py-1.5 px-3 rounded-lg bg-red-600 hover:bg-red-500 text-white font-bold text-xs transition-colors"
                                >
                                  {actionLoadingId === friend.friendship_id ? 'Removendo...' : 'Confirmar'}
                                </button>
                                <button
                                  type="button"
                                  onClick={() => setConfirmRemoveFriendId(null)}
                                  className="py-1.5 px-3 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-semibold transition-colors"
                                >
                                  Cancelar
                                </button>
                              </div>
                            </div>
                          ) : (
                            <div className="flex items-center gap-2 pt-1 border-t border-slate-800/60">
                              {/* Botão de Desafio / Jogar */}
                              <button
                                type="button"
                                onClick={() => onPlayWithFriend?.(friend)}
                                className="flex-1 py-2 px-3 rounded-xl bg-blue-600/20 hover:bg-blue-600 border border-blue-500/40 hover:border-blue-500 text-blue-300 hover:text-white font-bold text-xs transition-all flex items-center justify-center gap-1.5 active:scale-95"
                              >
                                <Swords className="w-3.5 h-3.5" />
                                <span>Desafiar</span>
                              </button>

                              {/* Botão de Chat */}
                              <button
                                type="button"
                                onClick={() => onOpenChatWithFriend?.(friend.user_id)}
                                className="py-2 px-3 rounded-xl bg-slate-800/90 hover:bg-slate-700 border border-slate-700/80 text-slate-200 text-xs font-semibold transition-all flex items-center justify-center gap-1.5 active:scale-95"
                                title="Conversar"
                              >
                                <MessageSquare className="w-3.5 h-3.5 text-violet-400" />
                                <span className="hidden sm:inline">Chat</span>
                              </button>

                              {/* Remover dos amigos */}
                              <button
                                type="button"
                                onClick={() => setConfirmRemoveFriendId(friend.friendship_id)}
                                className="p-2 rounded-xl bg-slate-800/40 hover:bg-red-950/50 border border-transparent hover:border-red-800/60 text-slate-500 hover:text-red-400 text-xs transition-all"
                                title="Remover amigo"
                              >
                                <Trash2 className="w-3.5 h-3.5" />
                              </button>
                            </div>
                          )}
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            )}

            {/* TAB 2: SOLICITAÇÕES */}
            {activeTab === 'requests' && (
              <div className="space-y-6 animate-fade-in">
                {/* Recebidas */}
                <div className="space-y-3">
                  <div className="flex items-center justify-between">
                    <h3 className="text-sm font-bold text-white flex items-center gap-2">
                      <UserPlus className="w-4 h-4 text-amber-400" />
                      <span>Solicitações Recebidas ({receivedRequests.length})</span>
                    </h3>
                  </div>

                  {receivedRequests.length === 0 ? (
                    <div className="p-6 rounded-2xl bg-slate-900/40 border border-slate-800/80 text-center text-xs text-slate-500">
                      Nenhuma solicitação de amizade pendente no momento.
                    </div>
                  ) : (
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                      {receivedRequests.map((req) => (
                        <div
                          key={req.request_id}
                          className="p-4 rounded-2xl bg-slate-900 border border-amber-500/30 flex items-center justify-between gap-3 shadow-md"
                        >
                          <div
                            onClick={() => onViewUserProfile?.(req.sender.user_id)}
                            className="flex items-center gap-3 cursor-pointer min-w-0"
                          >
                            <PlayerAvatar
                              avatarUrl={req.sender.avatar_url}
                              displayName={req.sender.display_name}
                              size="md"
                            />
                            <div className="min-w-0">
                              <h4 className="text-sm font-bold text-white truncate">
                                {req.sender.display_name}
                              </h4>
                              <span className="text-xs text-slate-400 truncate block">
                                @{req.sender.username}
                              </span>
                            </div>
                          </div>

                          <div className="flex items-center gap-2 shrink-0">
                            <button
                              type="button"
                              onClick={() => handleAccept(req.request_id)}
                              disabled={actionLoadingId === req.request_id}
                              className="py-1.5 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white font-bold text-xs transition-colors flex items-center gap-1 active:scale-95 shadow-sm"
                            >
                              <Check className="w-3.5 h-3.5" />
                              <span>Aceitar</span>
                            </button>
                            <button
                              type="button"
                              onClick={() => handleDecline(req.request_id)}
                              disabled={actionLoadingId === req.request_id}
                              className="p-1.5 rounded-xl bg-slate-800 hover:bg-red-950/60 hover:text-red-300 text-slate-400 text-xs transition-colors"
                              title="Recusar"
                            >
                              <X className="w-4 h-4" />
                            </button>
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>

                {/* Enviadas */}
                <div className="space-y-3 pt-4 border-t border-slate-800/80">
                  <h3 className="text-sm font-bold text-slate-300 flex items-center gap-2">
                    <Clock className="w-4 h-4 text-slate-400" />
                    <span>Solicitações Enviadas Aguardando Resposta ({sentRequests.length})</span>
                  </h3>

                  {sentRequests.length === 0 ? (
                    <div className="p-6 rounded-2xl bg-slate-900/40 border border-slate-800/80 text-center text-xs text-slate-500">
                      Você não tem convites de amizade aguardando resposta.
                    </div>
                  ) : (
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                      {sentRequests.map((req) => (
                        <div
                          key={req.request_id}
                          className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 flex items-center justify-between gap-3"
                        >
                          <div
                            onClick={() => onViewUserProfile?.(req.receiver.user_id)}
                            className="flex items-center gap-3 cursor-pointer min-w-0"
                          >
                            <PlayerAvatar
                              avatarUrl={req.receiver.avatar_url}
                              displayName={req.receiver.display_name}
                              size="sm"
                            />
                            <div className="min-w-0">
                              <h4 className="text-sm font-bold text-white truncate">
                                {req.receiver.display_name}
                              </h4>
                              <span className="text-xs text-slate-400 truncate block">
                                @{req.receiver.username}
                              </span>
                            </div>
                          </div>

                          <button
                            type="button"
                            onClick={() => handleCancel(req.request_id)}
                            disabled={actionLoadingId === req.request_id}
                            className="py-1.5 px-3 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-400 hover:text-slate-200 text-xs font-semibold transition-colors"
                          >
                            Cancelar
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* TAB 3: BUSCAR JOGADORES */}
            {activeTab === 'search' && (
              <div className="space-y-5 animate-fade-in">
                {/* Search Box Prominente */}
                <div className="p-6 rounded-3xl bg-slate-900/90 border border-slate-800/90 space-y-4 shadow-lg">
                  <div className="space-y-1">
                    <h3 className="text-base font-bold text-white flex items-center gap-2">
                      <Search className="w-5 h-5 text-blue-400" />
                      <span>Buscar Competidores na Plataforma</span>
                    </h3>
                    <p className="text-xs text-slate-400">
                      Digite o nome de exibição ou @username do jogador que você procura.
                    </p>
                  </div>

                  <div className="relative">
                    <Search className="w-5 h-5 absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" />
                    <input
                      type="text"
                      value={searchQuery}
                      onChange={(e) => setSearchQuery(e.target.value)}
                      placeholder="Ex: @alex, Rodrigo, ProGamer..."
                      autoFocus
                      className="w-full pl-12 pr-10 py-3.5 rounded-2xl bg-slate-950 border border-slate-800 text-sm sm:text-base text-slate-100 placeholder-slate-500 focus:outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 transition-all"
                    />
                    {searchQuery && (
                      <button
                        type="button"
                        onClick={() => {
                          setSearchQuery('');
                          setSearchResults([]);
                        }}
                        className="absolute right-3.5 top-1/2 -translate-y-1/2 p-1 text-slate-400 hover:text-white"
                      >
                        <X className="w-4 h-4" />
                      </button>
                    )}
                  </div>
                </div>

                {/* Status da Busca */}
                {isSearching && (
                  <div className="p-8 text-center space-y-2">
                    <div className="w-6 h-6 border-2 border-blue-500 border-t-transparent rounded-full animate-spin mx-auto" />
                    <p className="text-xs text-slate-400 font-medium">Buscando jogadores...</p>
                  </div>
                )}

                {searchError && (
                  <div className="p-4 rounded-2xl bg-red-950/50 border border-red-800 text-xs text-red-300 flex items-center gap-2">
                    <AlertCircle className="w-4 h-4 text-red-400 shrink-0" />
                    <span>{searchError}</span>
                  </div>
                )}

                {/* Resultados da Busca */}
                {!isSearching && searchResults.length > 0 && (
                  <div className="space-y-3">
                    <span className="text-xs font-semibold text-slate-400 uppercase tracking-wider block">
                      {searchResults.length} {searchResults.length === 1 ? 'jogador encontrado' : 'jogadores encontrados'}
                    </span>

                    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                      {searchResults.map((player) => {
                        const isFriend = player.friendship_status === 'accepted';
                        const isPendingSent = player.friendship_status === 'pending_sent';
                        const isPendingReceived = player.friendship_status === 'pending_received';
                        const isLoadingThis = actionLoadingId === player.user_id;

                        return (
                          <div
                            key={player.user_id}
                            className="p-4 rounded-2xl bg-slate-900/90 border border-slate-800 flex items-center justify-between gap-3 shadow-sm hover:border-slate-700 transition-all"
                          >
                            <div
                              onClick={() => onViewUserProfile?.(player.user_id)}
                              className="flex items-center gap-3 cursor-pointer min-w-0"
                            >
                              <PlayerAvatar
                                avatarUrl={player.avatar_url}
                                displayName={player.display_name}
                                size="md"
                              />
                              <div className="min-w-0">
                                <h4 className="text-sm font-bold text-white truncate hover:text-blue-300">
                                  {player.display_name}
                                </h4>
                                <span className="text-xs text-slate-400 truncate block">
                                  @{player.username}
                                </span>
                              </div>
                            </div>

                            <div className="shrink-0">
                              {isFriend ? (
                                <span className="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-xl bg-emerald-950/60 border border-emerald-600/40 text-emerald-300 text-xs font-bold">
                                  <Check className="w-3.5 h-3.5" />
                                  <span>Amigos</span>
                                </span>
                              ) : isPendingSent ? (
                                <span className="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-xl bg-slate-800 text-slate-400 text-xs font-semibold">
                                  <Clock className="w-3.5 h-3.5" />
                                  <span>Enviado</span>
                                </span>
                              ) : isPendingReceived ? (
                                <button
                                  type="button"
                                  onClick={() => setActiveTab('requests')}
                                  className="px-3 py-1.5 rounded-xl bg-amber-600 hover:bg-amber-500 text-white text-xs font-bold transition-all shadow-sm"
                                >
                                  Ver Convite
                                </button>
                              ) : (
                                <button
                                  type="button"
                                  onClick={() => handleSendRequest(player.user_id)}
                                  disabled={isLoadingThis}
                                  className="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white text-xs font-bold transition-all shadow-md active:scale-95 disabled:opacity-50"
                                >
                                  <UserPlus className="w-3.5 h-3.5" />
                                  <span>{isLoadingThis ? 'Enviando...' : 'Adicionar'}</span>
                                </button>
                              )}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}

                {/* Nenhum resultado */}
                {!isSearching && searchQuery.length >= 2 && searchResults.length === 0 && !searchError && (
                  <div className="p-10 rounded-2xl bg-slate-900/40 border border-slate-800 text-center space-y-2 text-slate-400">
                    <Users className="w-8 h-8 stroke-1 text-slate-600 mx-auto" />
                    <p className="text-sm font-medium">Nenhum jogador encontrado com "{searchQuery}"</p>
                    <p className="text-xs text-slate-500">
                      Verifique a ortografia do nome ou username.
                    </p>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
};
