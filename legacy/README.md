# Projeto base (referência)

Código apresentado aos investidores, preservado sem alteração para comparação
"antes × depois" na apresentação. **Não é compilado nem executado pelo sistema novo.**

Serve como especificação de comportamento do processamento:

- extração a `fps=1`, PNG no padrão `frame_%04d.png`;
- ZIP flat com deflate;
- extensões aceitas: mp4, avi, mov, mkv, wmv, flv, webm.

Problemas que a nova arquitetura resolve: ffmpeg síncrono dentro da requisição HTTP,
ausência de banco (status vinha de `filepath.Glob` no disco), ausência de autenticação,
de fila, de testes e de CI/CD.
