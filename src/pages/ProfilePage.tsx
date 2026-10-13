// ============================================================================
// Page: ProfilePage — DuoPlay-Online
// Phase: Transformação de Modais em Páginas Dedicadas & Perfil Gamer
// Description: Página completa para Perfil do Jogador (tanto próprio quanto público
//              de outros competidores), com edição de avatar e nome, estatísticas,
//              progressão de nível, histórico de duelos e conquistas.
// ============================================================================

import React, { useState, useEffect } from 'react';
import {
  ArrowLeft,
  Trophy,
  Swords,
  Calendar,
  Edit3,
  Check,
  AlertCircle,
  RefreshCw,
  History,
  ShieldCheck,
  Percent,
  Sparkles,
  Zap,
  Flame,
  MessageSquare,
  UserPlus,
  UserCheck,
  Trash2,
  ExternalLink,
  Crown,
  Medal,
  Award,
  Gamepad2,
  LogIn,
  X,
} from 'lucide-react';
import { useAuth } from '@/hooks/useAuth';
import { PlayerAvatar } from '@/components/profile/PlayerAvatar';
import { calculateLevelProgress } from '@/services/stats';
import {
  updateMyProfile,
  PRESET_AVATARS,
  validateUsername,
  validateDisplayName,
  fetchPublicProfile,
  type PlayerProfile,
  type PublicPlayerProfile,
} from '@/services/profile';
import { getMyMatchHistory, type MatchHistoryItem } from '@/services/matchHistory';
import { AchievementsList } from '@/components/profile/AchievementsList';
import {
  getFriendshipStatus,
  sendFriendRequest,
  acceptFriendRequest,
  declineFriendRequest,
  cancelFriendRequest,
  removeFriend,
} from '@/services/social';
import type { FriendshipStatusData } from '@/types/social';

export interface ProfilePageProps {
  onNavigateHome: () => void;
  targetUserId?: string | null;
  onOpenHistory?: () => void;
  onPlayWithPlayer?: (userId: string) => void;
  onOpenChatWithPlayer?: (userId: string) => void;
  onOpenAuth?: () => void;
}

export const ProfilePage: React.FC<ProfilePageProps> = ({
  onNavigateHome,
  targetUserId,
  onOpenHistory,
  onPlayWithPlayer,
  onOpenChatWithPlayer,
  onOpenAuth,
}) => {
  const { user, profile, refreshProfile, isAuthenticated, isLoading: isAuthLoading } = useAuth();

  const isOwnProfile = !targetUserId || targetUserId === user?.id;

  // Estado para visualização de perfil público de outro jogador
  const [publicProfile, setPublicProfile] = useState<PublicPlayerProfile | null>(null);
  const [socialStatus, setSocialStatus] = useState<FriendshipStatusData | null>(null);
  const [isPublicLoading, setIsPublicLoading] = useState(false);
  const [isSocialActionLoading, setIsSocialActionLoading] = useState(false);
  const [publicErrorMsg, setPublicErrorMsg] = useState<string | null>(null);
  const [isConfirmingRemove, setIsConfirmingRemove] = useState(false);

  // Estado para perfil próprio
  const [isEditing, setIsEditing] = useState(false);
  const [activeTab, setActiveTab] = useState<'stats' | 'achievements'>('stats');
  const [displayNameInput, setDisplayNameInput] = useState('');
  const [usernameInput, setUsernameInput] = useState('');
  const [selectedAvatarUrl, setSelectedAvatarUrl] = useState<string | null>(null);
  const [customAvatarInput, setCustomAvatarInput] = useState('');

  const [isSaving, setIsSaving] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  // Histórico recente para o perfil próprio
  const [recentMatches, setRecentMatches] = useState<MatchHistoryItem[]>([]);
  const [isLoadingHistory, setIsLoadingHistory] = useState(false);

  // Carrega dados iniciais do perfil próprio
  useEffect(() => {
    if (isOwnProfile && profile) {
      setDisplayNameInput(profile.display_name || '');
      setUsernameInput(profile.username || '');
      setSelectedAvatarUrl(profile.avatar_url || null);
      setCustomAvatarInput(profile.avatar_url || '');
      setErrorMessage(null);
      setSuccessMessage(null);
    }
  }, [isOwnProfile, profile, isEditing]);

  // Carrega histórico recente do usuário logado
  useEffect(() => {
    if (!isOwnProfile || !user) return;

    let isMounted = true;
    setIsLoadingHistory(true);

    getMyMatchHistory(5, 0)
      .then((res) => {
        if (isMounted && res.success && res.data) {
          setRecentMatches(res.data.matches);
        }
      })
      .catch(() => {})
      .finally(() => {
        if (isMounted) setIsLoadingHistory(false);
      });

    return () => {
      isMounted = false;
    };
  }, [isOwnProfile, user]);

  // Carrega perfil público de outro competidor
  useEffect(() => {
    if (isOwnProfile || !targetUserId) {
      setPublicProfile(null);
      setSocialStatus(null);
      return;
    }

    let isMounted = true;
    setIsPublicLoading(true);
    setPublicErrorMsg(null);

    Promise.all([
      fetchPublicProfile(targetUserId),
      getFriendshipStatus(targetUserId, true),
    ])
      .then(([profRes, socRes]) => {
        if (!isMounted) return;
        if (profRes.success && profRes.data) {
          setPublicProfile(profRes.data);
        } else {
          setPublicErrorMsg(profRes.error || 'Não foi possível carregar o perfil do jogador.');
        }

        if (socRes.success && socRes.data) {
          setSocialStatus(socRes.data);
        }
      })
      .catch(() => {
        if (isMounted) setPublicErrorMsg('Erro ao carregar dados do competidor.');
      })
      .finally(() => {
        if (isMounted) setIsPublicLoading(false);
      });

    return () => {
      isMounted = false;
    };
  }, [isOwnProfile, targetUserId]);

  // Ações de salvamento do perfil próprio
  const handleSaveProfile = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMessage(null);
    setSuccessMessage(null);

    const valDisplay = validateDisplayName(displayNameInput);
    if (!valDisplay.valid) {
      setErrorMessage(valDisplay.error || 'Nome de exibição inválido.');
      return;
    }

    const valUser = validateUsername(usernameInput);
    if (!valUser.valid) {
      setErrorMessage(valUser.error || 'Nome de usuário inválido.');
      return;
    }

    setIsSaving(true);
    try {
      const finalAvatar = customAvatarInput.trim() || selectedAvatarUrl;
      const res = await updateMyProfile({
        displayName: displayNameInput.trim(),
        username: usernameInput.trim().toLowerCase(),
        avatarUrl: finalAvatar || null,
      });

      if (res.success) {
        setSuccessMessage('Perfil atualizado com sucesso!');
        setIsEditing(false);
        await refreshProfile();
      } else {
        setErrorMessage(res.error || 'Falha ao salvar o perfil.');
      }
    } catch {
      setErrorMessage('Erro de conexão ao salvar.');
    } finally {
      setIsSaving(false);
    }
  };

  // Ações sociais para o perfil de outro usuário
  const handleSendFriendRequest = async () => {
    if (!targetUserId || isSocialActionLoading) return;
    setIsSocialActionLoading(true);
    const res = await sendFriendRequest(targetUserId);
    setIsSocialActionLoading(false);
    if (res.success) {
      setSocialStatus((prev) =>
        prev
          ? {
              ...prev,
              status: res.data?.action === 'mutual_accepted' ? 'friends' : 'request_sent',
              request_id: res.data?.request_id || null,
            }
          : null
      );
    }
  };

  const handleAcceptFriendRequest = async () => {
    if (!socialStatus?.request_id || isSocialActionLoading) return;
    setIsSocialActionLoading(true);
    const res = await acceptFriendRequest(socialStatus.request_id);
    setIsSocialActionLoading(false);
    if (res.success) {
      setSocialStatus((prev) => (prev ? { ...prev, status: 'friends' } : null));
    }
  };

  const handleCancelFriendRequest = async () => {
    if (!socialStatus?.request_id || isSocialActionLoading) return;
    setIsSocialActionLoading(true);
    const res = await cancelFriendRequest(socialStatus.request_id);
    setIsSocialActionLoading(false);
    if (res.success) {
      setSocialStatus((prev) => (prev ? { ...prev, status: 'none', request_id: null } : null));
    }
  };

  const handleRemoveFriend = async () => {
    if (!targetUserId || isSocialActionLoading) return;
    setIsSocialActionLoading(true);
    const res = await removeFriend(targetUserId);
    setIsSocialActionLoading(false);
    setIsConfirmingRemove(false);
    if (res.success) {
      setSocialStatus((prev) => (prev ? { ...prev, status: 'none', request_id: null } : null));
    }
  };

  // Se não autenticado e tentando ver o próprio perfil
  if (isOwnProfile && !isAuthenticated && !isAuthLoading) {
    return (
      <div className="min-h-screen pb-24 md:pb-16 text-slate-100 flex flex-col justify-center items-center px-4">
        <div className="p-8 sm:p-12 rounded-3xl bg-slate-900 border border-slate-800 text-center max-w-md w-full shadow-2xl space-y-5">
          <div className="w-16 h-16 rounded-2xl bg-blue-600/20 border border-blue-500/40 flex items-center justify-center text-blue-400 mx-auto">
            <Trophy className="w-8 h-8" />
          </div>
          <div className="space-y-2">
            <h2 className="text-xl font-bold text-white">Acesse o seu Perfil</h2>
            <p className="text-xs text-slate-400">
              Faça login para acompanhar seu histórico, subir de nível, colecionar conquistas e personalizar seu avatar.
            </p>
          </div>
          <div className="flex flex-col gap-3">
            {onOpenAuth && (
              <button
                type="button"
                onClick={onOpenAuth}
                className="w-full py-3 px-4 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white font-bold text-sm shadow-lg shadow-blue-950/50 transition-all active:scale-95 flex items-center justify-center gap-2"
              >
                <LogIn className="w-4 h-4" />
                <span>Entrar ou Criar Conta</span>
              </button>
            )}
            <button
              type="button"
              onClick={onNavigateHome}
              className="w-full py-2.5 px-4 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-semibold transition-colors"
            >
              Voltar aos Jogos
            </button>
          </div>
        </div>
      </div>
    );
  }

  // --------------------------------------------------------------------------
  // RENDER: PERFIL PÚBLICO DE OUTRO COMPETIDOR
  // --------------------------------------------------------------------------
  if (!isOwnProfile) {
    return (
      <div className="min-h-screen pb-24 md:pb-16 text-slate-100">
        {/* Header Bar */}
        <div className="border-b border-slate-800/80 bg-slate-950/70 backdrop-blur-md sticky top-16 z-20">
          <div className="max-w-4xl mx-auto px-4 sm:px-6 py-4 flex items-center justify-between">
            <button
              type="button"
              onClick={onNavigateHome}
              className="inline-flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 hover:bg-slate-800 text-slate-300 hover:text-white text-xs font-bold transition-all active:scale-95 shadow-sm"
            >
              <ArrowLeft className="w-4 h-4 text-purple-400" />
              <span>Voltar aos Jogos</span>
            </button>

            <span className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
              Perfil Público
            </span>
          </div>
        </div>

        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-6 sm:py-8 space-y-6">
          {isPublicLoading ? (
            <div className="p-12 text-center space-y-3">
              <div className="w-8 h-8 border-2 border-purple-500 border-t-transparent rounded-full animate-spin mx-auto" />
              <p className="text-xs text-slate-400">Carregando dados do competidor...</p>
            </div>
          ) : publicErrorMsg || !publicProfile ? (
            <div className="p-8 rounded-3xl bg-slate-900 border border-slate-800 text-center space-y-3">
              <p className="text-sm text-red-400">{publicErrorMsg || 'Jogador não encontrado.'}</p>
              <button
                type="button"
                onClick={onNavigateHome}
                className="px-4 py-2 rounded-xl bg-slate-800 text-xs font-bold text-white hover:bg-slate-700"
              >
                Voltar aos Jogos
              </button>
            </div>
          ) : (
            <>
              {/* Hero Banner do Competidor */}
              <div className="p-6 sm:p-8 rounded-3xl bg-gradient-to-br from-slate-900 via-purple-950/20 to-slate-900 border border-purple-900/40 shadow-2xl relative overflow-hidden space-y-6">
                <div className="flex flex-col sm:flex-row items-center sm:items-start gap-6 text-center sm:text-left">
                  <div className="relative">
                    <PlayerAvatar
                      avatarUrl={publicProfile?.avatarUrl}
                      displayName={publicProfile?.displayName}
                      size="xl"
                    />
                    <div className="absolute -bottom-2 -right-1 px-2 py-0.5 rounded-full bg-purple-600 text-[10px] font-black text-white border-2 border-slate-900 shadow">
                      NV {publicProfile?.stats?.level || 1}
                    </div>
                  </div>

                  <div className="space-y-1.5 flex-1 min-w-0">
                    <h1 className="text-2xl sm:text-3xl font-black text-white tracking-tight">
                      {publicProfile?.displayName || 'Competidor'}
                    </h1>
                    <span className="text-sm text-purple-300/80 block font-mono">
                      @{publicProfile?.username || 'competidor'}
                    </span>

                    <div className="flex flex-wrap items-center justify-center sm:justify-start gap-3 pt-2 text-xs text-slate-400">
                      <span className="flex items-center gap-1.5 bg-slate-800/80 px-2.5 py-1 rounded-lg">
                        <Calendar className="w-3.5 h-3.5 text-slate-500" />
                        Membro desde{' '}
                        {new Date(publicProfile?.createdAt || Date.now()).toLocaleDateString('pt-BR', {
                          month: 'short',
                          year: 'numeric',
                        })}
                      </span>
                    </div>
                  </div>

                  {/* Ações Sociais Contextuais */}
                  <div className="flex flex-wrap sm:flex-col gap-2 shrink-0 w-full sm:w-auto">
                    {onPlayWithPlayer && targetUserId && (
                      <button
                        type="button"
                        onClick={() => onPlayWithPlayer(targetUserId)}
                        className="flex-1 sm:flex-none py-2.5 px-4 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white font-bold text-xs shadow-md transition-all flex items-center justify-center gap-1.5 active:scale-95"
                      >
                        <Swords className="w-3.5 h-3.5" />
                        <span>Desafiar para Jogo</span>
                      </button>
                    )}

                    {onOpenChatWithPlayer && targetUserId && (
                      <button
                        type="button"
                        onClick={() => onOpenChatWithPlayer(targetUserId)}
                        className="flex-1 sm:flex-none py-2.5 px-4 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 font-bold text-xs transition-colors flex items-center justify-center gap-1.5"
                      >
                        <MessageSquare className="w-3.5 h-3.5 text-violet-400" />
                        <span>Enviar Mensagem</span>
                      </button>
                    )}

                    {/* Botão de Amizade */}
                    {isAuthenticated && (
                      <>
                        {socialStatus?.status === 'friends' ? (
                          isConfirmingRemove ? (
                            <div className="flex items-center gap-1.5">
                              <button
                                type="button"
                                onClick={handleRemoveFriend}
                                disabled={isSocialActionLoading}
                                className="py-2 px-3 rounded-xl bg-red-600 text-white text-xs font-bold"
                              >
                                Confirmar remoção
                              </button>
                              <button
                                type="button"
                                onClick={() => setIsConfirmingRemove(false)}
                                className="p-2 rounded-xl bg-slate-800 text-slate-300 text-xs"
                              >
                                <X className="w-4 h-4" />
                              </button>
                            </div>
                          ) : (
                            <button
                              type="button"
                              onClick={() => setIsConfirmingRemove(true)}
                              className="py-2 px-3 rounded-xl bg-slate-800/60 hover:bg-red-950/40 text-slate-400 hover:text-red-400 text-xs font-semibold transition-colors flex items-center justify-center gap-1.5"
                            >
                              <UserCheck className="w-3.5 h-3.5 text-emerald-400" />
                              <span>Amigos (Remover)</span>
                            </button>
                          )
                        ) : socialStatus?.status === 'request_sent' ? (
                          <button
                            type="button"
                            onClick={handleCancelFriendRequest}
                            disabled={isSocialActionLoading}
                            className="py-2 px-3 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-400 text-xs font-semibold transition-colors"
                          >
                            Cancelar Pedido
                          </button>
                        ) : socialStatus?.status === 'request_received' ? (
                          <button
                            type="button"
                            onClick={handleAcceptFriendRequest}
                            disabled={isSocialActionLoading}
                            className="py-2 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-bold transition-colors"
                          >
                            Aceitar Pedido de Amizade
                          </button>
                        ) : (
                          <button
                            type="button"
                            onClick={handleSendFriendRequest}
                            disabled={isSocialActionLoading}
                            className="py-2 px-3 rounded-xl bg-slate-800 hover:bg-purple-900/40 border border-slate-700 text-purple-300 text-xs font-bold transition-colors flex items-center justify-center gap-1.5"
                          >
                            <UserPlus className="w-3.5 h-3.5" />
                            <span>Adicionar aos Amigos</span>
                          </button>
                        )}
                      </>
                    )}
                  </div>
                </div>

                {/* Grid de Estatísticas Públicas */}
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 pt-4 border-t border-slate-800">
                  <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                    <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                      Partidas
                    </span>
                    <span className="text-xl font-black text-white mt-0.5 block">
                      {publicProfile?.stats?.totalMatches || 0}
                    </span>
                  </div>

                  <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                    <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                      Vitórias
                    </span>
                    <span className="text-xl font-black text-emerald-400 mt-0.5 block">
                      {publicProfile?.stats?.totalWins || 0}
                    </span>
                  </div>

                  <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                    <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                      Taxa de Vitória
                    </span>
                    <span className="text-xl font-black text-blue-400 mt-0.5 block">
                      {publicProfile?.stats?.winRate || 0}%
                    </span>
                  </div>

                  <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                    <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                      Nível Geral
                    </span>
                    <span className="text-xl font-black text-amber-400 mt-0.5 block">
                      {publicProfile?.stats?.level || 1}
                    </span>
                  </div>
                </div>
              </div>

              {/* Conquistas Desbloqueadas */}
              <div className="p-6 rounded-3xl bg-slate-900/80 border border-slate-800/80 space-y-4">
                <div className="flex items-center gap-2">
                  <Trophy className="w-5 h-5 text-amber-400" />
                  <h3 className="text-base font-bold text-white">Galeria de Conquistas</h3>
                </div>
                <AchievementsList userId={targetUserId || undefined} />
              </div>
            </>
          )}
        </div>
      </div>
    );
  }

  // --------------------------------------------------------------------------
  // RENDER: PERFIL PRÓPRIO DO USUÁRIO LOGADO
  // --------------------------------------------------------------------------
  const levelData = calculateLevelProgress(profile?.stats?.total_score || 0);

  return (
    <div className="min-h-screen pb-24 md:pb-16 text-slate-100">
      {/* Top Header Bar */}
      <div className="border-b border-slate-800/80 bg-slate-950/70 backdrop-blur-md sticky top-16 z-20">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 py-4 flex items-center justify-between">
          <button
            type="button"
            onClick={onNavigateHome}
            className="inline-flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 hover:bg-slate-800 text-slate-300 hover:text-white text-xs font-bold transition-all active:scale-95 shadow-sm"
          >
            <ArrowLeft className="w-4 h-4 text-blue-400" />
            <span>Voltar aos Jogos</span>
          </button>

          <div className="flex items-center gap-2">
            {!isEditing && (
              <button
                type="button"
                onClick={() => setIsEditing(true)}
                className="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-blue-600/20 hover:bg-blue-600 border border-blue-500/40 text-blue-300 hover:text-white text-xs font-bold transition-all active:scale-95"
              >
                <Edit3 className="w-3.5 h-3.5" />
                <span>Editar Perfil</span>
              </button>
            )}
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 sm:px-6 py-6 sm:py-8 space-y-6">
        {/* Banner com Feedback de Sucesso ou Erro */}
        {successMessage && (
          <div className="p-4 rounded-2xl bg-emerald-950/60 border border-emerald-800 text-xs text-emerald-300 flex items-center gap-2 animate-fade-in">
            <Check className="w-4 h-4 text-emerald-400 shrink-0" />
            <span>{successMessage}</span>
          </div>
        )}
        {errorMessage && (
          <div className="p-4 rounded-2xl bg-red-950/60 border border-red-800 text-xs text-red-300 flex items-center gap-2 animate-fade-in">
            <AlertCircle className="w-4 h-4 text-red-400 shrink-0" />
            <span>{errorMessage}</span>
          </div>
        )}

        {/* MODO EDIÇÃO DO PERFIL */}
        {isEditing ? (
          <form
            onSubmit={handleSaveProfile}
            className="p-6 sm:p-8 rounded-3xl bg-slate-900 border border-slate-800 space-y-6 shadow-2xl animate-fade-in"
          >
            <div className="flex items-center justify-between border-b border-slate-800 pb-4">
              <h2 className="text-lg font-bold text-white flex items-center gap-2">
                <Edit3 className="w-5 h-5 text-blue-400" />
                <span>Editar Informações do Jogador</span>
              </h2>
              <button
                type="button"
                onClick={() => setIsEditing(false)}
                className="p-1.5 rounded-lg text-slate-400 hover:text-white"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            {/* Seleção de Avatar Preset */}
            <div className="space-y-3">
              <label className="text-xs font-bold text-slate-300 uppercase tracking-wider block">
                Escolha seu Avatar Gamer
              </label>
              <div className="grid grid-cols-4 sm:grid-cols-8 gap-2.5">
                {PRESET_AVATARS.map((url, idx) => (
                  <button
                    key={idx}
                    type="button"
                    onClick={() => {
                      setSelectedAvatarUrl(url);
                      setCustomAvatarInput('');
                    }}
                    className={`p-1 rounded-2xl border-2 transition-all relative ${
                      selectedAvatarUrl === url && !customAvatarInput
                        ? 'border-blue-500 scale-105 shadow-md shadow-blue-500/30'
                        : 'border-slate-800 hover:border-slate-700 opacity-70 hover:opacity-100'
                    }`}
                  >
                    <img
                      src={url}
                      alt={`Avatar ${idx + 1}`}
                      className="w-full aspect-square rounded-xl object-cover"
                    />
                    {selectedAvatarUrl === url && !customAvatarInput && (
                      <div className="absolute top-1 right-1 w-4 h-4 rounded-full bg-blue-600 text-white flex items-center justify-center">
                        <Check className="w-3 h-3 stroke-[3]" />
                      </div>
                    )}
                  </button>
                ))}
              </div>

              {/* URL Customizada */}
              <div className="pt-2">
                <input
                  type="url"
                  value={customAvatarInput}
                  onChange={(e) => setCustomAvatarInput(e.target.value)}
                  placeholder="Ou cole o link de uma imagem externa (URL)..."
                  className="w-full px-4 py-2.5 rounded-xl bg-slate-950 border border-slate-800 text-xs text-slate-100 placeholder-slate-500 focus:outline-none focus:border-blue-500"
                />
              </div>
            </div>

            {/* Inputs de Nome e Username */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div className="space-y-1.5">
                <label className="text-xs font-bold text-slate-300 block">
                  Nome de Exibição
                </label>
                <input
                  type="text"
                  value={displayNameInput}
                  onChange={(e) => setDisplayNameInput(e.target.value)}
                  maxLength={30}
                  className="w-full px-4 py-2.5 rounded-xl bg-slate-950 border border-slate-800 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:border-blue-500"
                />
                <span className="text-[10px] text-slate-500">De 2 a 30 caracteres</span>
              </div>

              <div className="space-y-1.5">
                <label className="text-xs font-bold text-slate-300 block">
                  Nome de Usuário (@tag única)
                </label>
                <div className="relative">
                  <span className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-500 text-sm font-bold">@</span>
                  <input
                    type="text"
                    value={usernameInput}
                    onChange={(e) => setUsernameInput(e.target.value)}
                    maxLength={20}
                    className="w-full pl-8 pr-4 py-2.5 rounded-xl bg-slate-950 border border-slate-800 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:border-blue-500 font-mono"
                  />
                </div>
                <span className="text-[10px] text-slate-500">Apenas letras, números e underlines</span>
              </div>
            </div>

            {/* Ações de Salvar / Cancelar */}
            <div className="flex items-center justify-end gap-3 pt-4 border-t border-slate-800">
              <button
                type="button"
                onClick={() => setIsEditing(false)}
                className="py-2.5 px-4 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-bold transition-colors"
              >
                Cancelar
              </button>
              <button
                type="submit"
                disabled={isSaving}
                className="py-2.5 px-6 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-xs font-bold shadow-md transition-all active:scale-95 disabled:opacity-50"
              >
                {isSaving ? 'Salvando...' : 'Salvar Alterações'}
              </button>
            </div>
          </form>
        ) : (
          /* MODO VISUALIZAÇÃO DO PERFIL PRÓPRIO */
          <>
            {/* Hero Card do Jogador */}
            <div className="p-6 sm:p-8 rounded-3xl bg-gradient-to-br from-slate-900 via-blue-950/20 to-slate-900 border border-blue-900/40 shadow-2xl space-y-6 relative overflow-hidden">
              <div className="flex flex-col sm:flex-row items-center sm:items-start gap-6 text-center sm:text-left">
                <div className="relative">
                  <PlayerAvatar
                    avatarUrl={profile?.avatar_url}
                    displayName={profile?.display_name}
                    size="xl"
                  />
                  <div className="absolute -bottom-2 -right-1 px-2.5 py-0.5 rounded-full bg-blue-600 text-[10px] font-black text-white border-2 border-slate-900 shadow">
                    NV {levelData.level}
                  </div>
                </div>

                <div className="space-y-1.5 flex-1 min-w-0">
                  <div className="flex flex-col sm:flex-row sm:items-center gap-2">
                    <h1 className="text-2xl sm:text-3xl font-black text-white tracking-tight">
                      {profile?.display_name || user?.email?.split('@')[0]}
                    </h1>
                    <span className="px-2 py-0.5 rounded-full bg-emerald-500/20 border border-emerald-500/30 text-emerald-400 text-[10px] font-bold self-center sm:self-auto">
                      Conta Oficial
                    </span>
                  </div>

                  <span className="text-sm text-blue-300/80 block font-mono">
                    @{profile?.username || 'jogador'}
                  </span>

                  {/* Barra de Progresso de Nível */}
                  <div className="pt-3 max-w-md space-y-1.5">
                    <div className="flex items-center justify-between text-xs">
                      <span className="font-bold text-amber-400 flex items-center gap-1">
                        <Crown className="w-3.5 h-3.5" />
                        Nível {levelData.level}
                      </span>
                      <span className="text-slate-400 text-[11px]">
                        {levelData.currentLevelXp} / {levelData.xpForNextLevel} XP
                      </span>
                    </div>
                    <div className="w-full h-2 rounded-full bg-slate-800 overflow-hidden">
                      <div
                        className="h-full rounded-full bg-gradient-to-r from-amber-500 to-yellow-400 transition-all duration-500"
                        style={{ width: `${levelData.progressPercent}%` }}
                      />
                    </div>
                  </div>
                </div>

                <div className="shrink-0 flex sm:flex-col gap-2">
                  <button
                    type="button"
                    onClick={() => setIsEditing(true)}
                    className="py-2 px-3.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-bold transition-all flex items-center gap-1.5"
                  >
                    <Edit3 className="w-3.5 h-3.5" />
                    <span>Editar</span>
                  </button>

                  {onOpenHistory && (
                    <button
                      type="button"
                      onClick={onOpenHistory}
                      className="py-2 px-3.5 rounded-xl bg-slate-800/80 hover:bg-slate-700 text-slate-300 text-xs font-semibold transition-all flex items-center gap-1.5"
                    >
                      <History className="w-3.5 h-3.5" />
                      <span>Histórico</span>
                    </button>
                  )}
                </div>
              </div>

              {/* Grid de Métricas Principais */}
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 pt-4 border-t border-slate-800">
                <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                    Partidas Jogadas
                  </span>
                  <span className="text-xl font-black text-white mt-0.5 block">
                    {profile?.stats?.total_matches || 0}
                  </span>
                </div>

                <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                    Vitórias Oficiais
                  </span>
                  <span className="text-xl font-black text-emerald-400 mt-0.5 block">
                    {profile?.stats?.total_wins || 0}
                  </span>
                </div>

                <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                    Taxa de Vitória
                  </span>
                  <span className="text-xl font-black text-blue-400 mt-0.5 block">
                    {profile?.stats?.win_rate || 0}%
                  </span>
                </div>

                <div className="p-3.5 rounded-2xl bg-slate-900/80 border border-slate-800 text-center">
                  <span className="text-[10px] text-slate-500 font-bold uppercase tracking-wider block">
                    Pontuação Geral
                  </span>
                  <span className="text-xl font-black text-amber-400 mt-0.5 block">
                    {profile?.stats?.total_score || 0}
                  </span>
                </div>
              </div>
            </div>

            {/* Abas: Estatísticas & Histórico vs Conquistas */}
            <div className="flex p-1.5 bg-slate-900/90 rounded-2xl border border-slate-800/90 max-w-md">
              <button
                type="button"
                onClick={() => setActiveTab('stats')}
                className={`flex-1 py-2 px-3 rounded-xl text-xs sm:text-sm font-bold transition-all flex items-center justify-center gap-2 ${
                  activeTab === 'stats'
                    ? 'bg-blue-600 text-white shadow-md'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                <Trophy className="w-4 h-4" />
                <span>Histórico & Resumo</span>
              </button>
              <button
                type="button"
                onClick={() => setActiveTab('achievements')}
                className={`flex-1 py-2 px-3 rounded-xl text-xs sm:text-sm font-bold transition-all flex items-center justify-center gap-2 ${
                  activeTab === 'achievements'
                    ? 'bg-blue-600 text-white shadow-md'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                <Award className="w-4 h-4" />
                <span>Conquistas</span>
              </button>
            </div>

            {/* Conteúdo da Aba Histórico & Resumo */}
            {activeTab === 'stats' && (
              <div className="space-y-6 animate-fade-in">
                {/* Histórico Recente */}
                <div className="p-6 rounded-3xl bg-slate-900/80 border border-slate-800/80 space-y-4">
                  <div className="flex items-center justify-between">
                    <h3 className="text-sm font-bold text-white flex items-center gap-2">
                      <History className="w-4 h-4 text-blue-400" />
                      <span>Últimas Partidas Disputadas</span>
                    </h3>
                    {onOpenHistory && (
                      <button
                        type="button"
                        onClick={onOpenHistory}
                        className="text-xs text-blue-400 hover:text-blue-300 font-semibold"
                      >
                        Ver histórico completo →
                      </button>
                    )}
                  </div>

                  {isLoadingHistory ? (
                    <div className="space-y-2">
                      {[1, 2, 3].map((i) => (
                        <div key={i} className="h-14 rounded-2xl bg-slate-800/50 animate-pulse" />
                      ))}
                    </div>
                  ) : recentMatches.length === 0 ? (
                    <div className="p-8 rounded-2xl bg-slate-950/50 border border-slate-800/80 text-center space-y-2 text-slate-400 text-xs">
                      <Gamepad2 className="w-6 h-6 stroke-1 mx-auto text-slate-600" />
                      <p>Nenhuma partida disputada ainda.</p>
                      <button
                        type="button"
                        onClick={onNavigateHome}
                        className="text-blue-400 hover:underline font-bold"
                      >
                        Encontrar uma partida agora
                      </button>
                    </div>
                  ) : (
                    <div className="space-y-2">
                      {recentMatches.map((m) => {
                        const isWin = m.winner_id === user?.id;
                        const isDraw = m.is_draw;

                        return (
                          <div
                            key={m.match_id}
                            className="p-3.5 rounded-2xl bg-slate-950/60 border border-slate-800/80 flex items-center justify-between gap-3"
                          >
                            <div className="flex items-center gap-3">
                              <span
                                className={`px-2 py-1 rounded-lg text-[10px] font-black uppercase ${
                                  isWin
                                    ? 'bg-emerald-950 border border-emerald-500/40 text-emerald-400'
                                    : isDraw
                                    ? 'bg-amber-950 border border-amber-500/40 text-amber-400'
                                    : 'bg-red-950 border border-red-500/40 text-red-400'
                                }`}
                              >
                                {isWin ? 'Vitória' : isDraw ? 'Empate' : 'Derrota'}
                              </span>
                              <div>
                                <h4 className="text-xs font-bold text-white">{m.game_name}</h4>
                                <span className="text-[10px] text-slate-500">
                                  {new Date(m.created_at).toLocaleDateString('pt-BR', {
                                    day: '2-digit',
                                    month: '2-digit',
                                    hour: '2-digit',
                                    minute: '2-digit',
                                  })}
                                </span>
                              </div>
                            </div>

                            {m.opponents?.[0] && (
                              <div className="flex items-center gap-2 text-right">
                                <span className="text-xs text-slate-400">
                                  vs {m.opponents[0].display_name || m.opponents[0].username}
                                </span>
                                <PlayerAvatar
                                  avatarUrl={m.opponents[0].avatar_url}
                                  displayName={m.opponents[0].display_name}
                                  size="sm"
                                />
                              </div>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* Conteúdo da Aba Conquistas */}
            {activeTab === 'achievements' && (
              <div className="p-6 rounded-3xl bg-slate-900/80 border border-slate-800/80 space-y-4 animate-fade-in">
                <div className="flex items-center gap-2">
                  <Award className="w-5 h-5 text-amber-400" />
                  <h3 className="text-base font-bold text-white">Suas Conquistas</h3>
                </div>
                <AchievementsList />
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
};
