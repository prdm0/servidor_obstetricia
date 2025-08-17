# Instalação do R Local + Acesso ao Servidor USP

Este repositório contém um script `install_r.sh` que permite compilar e instalar a versão mais recente do R **diretamente no diretório do usuário**, sem necessidade de permissões de superusuário.

Também estão incluídas instruções para acesso ao servidor **obstetricia.fm.usp.br** via SSH.

---

## 🔑 Acesso ao Servidor USP

O servidor **obstetricia.fm.usp.br** utiliza um sistema de liberação temporária de porta SSH.

1. **Abrir o navegador** e acessar o endereço:

   ```
   http://obstetricia.fm.usp.br:35501
   ```

   > ⚠️ É normal aparecer uma página de erro. Basta dar **reload uma vez** para liberar o acesso.

2. **Em até 5 minutos** após abrir o link, execute no terminal:

   ```bash
   ssh pedro.marinho@obstetricia.fm.usp.br
   ```

Observação: Para não travar em 5 min, acesse por:

```bash
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=5 pedro.marinho@obstetricia.fm.usp.br
```

+ `ServerAliveInterval=60`: a cada 60 segundos o cliente envia um pacote vazio.

+ `ServerAliveCountMax=5`: se o servidor não responder 5 vezes seguidas, ele encerra.

3. Digite a sua senha de acesso (não será exibida na tela).
   > ⚠️ **Nunca compartilhe sua senha**.

Se o tempo de 5 minutos expirar, repita o processo: abra novamente o endereço no navegador e tente o SSH de novo.

---

## 📤 Enviando arquivos para o servidor

Para instalar o R localmente no servidor, você precisará enviar o script `install_r.sh` (ou qualquer outro arquivo necessário).

Isso é feito com o comando **scp** (Secure Copy).

Exemplo de envio do arquivo `install_r.sh` para o servidor:

```bash
scp ~/Downloads/install_r.sh pedro.marinho@obstetricia.fm.usp.br:~/install_r.sh
```

Explicação:
+ `~/Downloads/install_r.sh` → caminho do arquivo no seu computador local
+ `pedro.marinho@obstetricia.fm.usp.br` → usuário e servidor de destino
+ `:~/install_r.sh` → caminho onde o arquivo será salvo no servidor (aqui, no diretório home do usuário)

Após enviar o arquivo, conecte-se via SSH ao servidor e execute a instalação normalmente.

---

## 📦 Instalação do R Local

### 1. Dar permissão de execução ao script

```bash
sudo chmod +x install_r.sh
```

### 2. Executar o script

Por padrão, o script instala a última versão estável do R em:

```
~/.local/R/r_local_<versão>
```

e cria um link simbólico em:

```
~/.local/R/current
```

Além disso, adiciona os binários em `~/.local/bin`.

#### Exemplos de uso

+ Instalar a versão mais recente:

  ```bash
  ./install_r.sh
  ```

+ Instalar sem suporte gráfico (headless, ideal para servidores):

  ```bash
  ./install_r.sh --headless
  ```

+ Instalar uma versão específica:

  ```bash
  ./install_r.sh --version 4.5.1
  ```

+ Instalar mais rápido, sem os *Recommended packages*:

  ```bash
  ./install_r.sh --without-recommended
  ```

---

## ▶️ Como executar o R

Após a instalação, é necessário garantir que o diretório `~/.local/bin` esteja no **PATH** do sistema.

Adicione a seguinte linha ao final do arquivo `~/.bashrc` (ou `~/.zshrc` se usar Zsh):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Em seguida, recarregue o shell:

```bash
source ~/.bashrc
```

ou abra um novo terminal.

Agora, você pode simplesmente executar:

```bash
R
```

ou:

```bash
Rscript arquivo.R
```

---

## 📂 Estrutura final

Exemplo após instalar a versão `4.5.1`:

```
~/.local/R/r_local_4.5.1
~/.local/R/current   -> link para r_local_4.5.1
~/.local/bin/R
~/.local/bin/Rscript
```

---
