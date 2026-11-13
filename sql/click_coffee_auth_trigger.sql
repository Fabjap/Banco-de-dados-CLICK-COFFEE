
-- ETAPA 1465-D.9.3
-- Trigger complementar do Click & Coffee
-- Objeto associado ao esquema auth

CREATE TRIGGER trigger_criar_perfil_novo_usuario
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.criar_perfil_novo_usuario();
