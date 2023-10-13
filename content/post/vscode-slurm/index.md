---
# Documentation: https://wowchemy.com/docs/managing-content/

title: "Using VSCode in Slurm"
subtitle: ""
summary: ""
authors: []
tags: ["Slurm", "VSCode", "PyCharm"]
categories: []
date: 2023-08-07T15:10:29+02:00
lastmod: 2023-08-07T15:10:29+02:00
featured: false
draft: false

# Featured image
# To use, add an image named `featured.jpg/png` to your page's folder.
# Focal points: Smart, Center, TopLeft, Top, TopRight, Left, Right, BottomLeft, Bottom, BottomRight.
image:
  caption: ""
  focal_point: ""
  preview_only: false

# Projects (optional).
#   Associate this post with one or more of your projects.
#   Simply enter your project's folder or file name without extension.
#   E.g. `projects = ["internal-project"]` references `content/project/deep-learning/index.md`.
#   Otherwise, set `projects = []`.
projects: []
---

{{< toc >}}


Although I don't use Visual Studio Code[[1]] as a code editor (I use Neovim[[2]] 🦸), many colleagues use it as their primary editor. 

(The solution presented here also works for PyCharm[[4]]!)

## The problem

To develop in our Slurm[[3]] cluster, the users connect the VSCode to the "Login node" which starts the `vscode-server` process. 

This is not a problem by itself, but when many users do it simultaneously, it starts to consume many resources in a machine that should only be used to manage Slurm jobs.

Additionally, this setup only allows for editing the code, not for executing (or at least I hope they are not running code in the "Login node" 🤞) or even debugging. 

![htop](htop.png "The Login Node is full of `vscode-server` processes from many users taking 30GB of memory!")

## Advantages

In the following sections, I will explain how to run VSCode inside Slurm[[3]]. 

This solves the problem of adding load to the login node. Additionally, since the code editor process will live inside a Slurm job, we will be able to debug and run code directly in the job. That's very convenient!

## 🧑‍💻 The easy solution: VSCode on the web! 

This solution is super simple to set up! It consists of running `code-server`[[5]] as a Slurm job and accessing it through the web browser.

First, we need to install the binary in our system. There are many options for that, so just pick up the most convenient for you. See the list of options [here](https://coder.com/docs/code-server/latest/install). In my case, I choose the `Standalone release` and put the binary in my path.

Second, we will create a job file, for example `code-server.job`, with the following content:

```bash
#!/bin/bash 
 
#SBATCH --job-name=code-server
#SBATCH --time=04:00:00
#SBATCH --output=%x_%j_%N.log 

#SBATCH --mem=8gb 
#SBATCH --gpus=1 
#SBATCH --cpus-per-task=4 

#SBATCH -p submit
 
PASSWORD=1234 # TODO: Change to secure password
PORT=$(python -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

echo "********************************************************************" 
echo "Starting code-server in Slurm"
echo "Environment information:" 
echo "Date:" $(date)
echo "Allocated node:" $(hostname)
echo "Node IP:" $(ip a | grep 131.159)
echo "Path:" $(pwd)
echo "Password to access VSCode:" $PASSWORD
echo "Listening on:" $PORT
echo "********************************************************************" 

PASSWORD=$PASSWORD code-server --bind-addr 0.0.0.0:$PORT --auth password --disable-telemetry
```

❗ Remember to change the password! ❗

Finally, once the job has started, we can open the editor using any web browser and navigating to the `IP` of the node and the `PORT`.

That's it!

 If the node is not accessible from the Internet, use port-forwarding https://coder.com/docs/code-server/latest/guide#port-forwarding-via-ssh.

## 👷 The complex solution: Start your own `sshd` process

If you are up for a more complex solution or use other IDEs like PyCharm, you can use the next configuration. It involves starting `sshd` in a Slurm  job and then connecting our IDEs to the new process (instead of the global `sshd` process).

### Step 1: Create the SSH keys

```bash
ssh-keygen -t rsa -f .ssh/vcg_cluster_user_sshd
```

Then, copy the generated keys to the login node. (We assume here that the user's home directories are accessible on all nodes).

### Step 2: `sshd` Slurm job

Copy the following content to a new file such as `sshd.job`.

```bash
#!/bin/bash 
 
#SBATCH --job-name=sshd
#SBATCH --time=04:00:00
#SBATCH --output=%x_%j_%N.log 

#SBATCH --mem=8gb 
#SBATCH --gpus=1 
#SBATCH --cpus-per-task=4 

#SBATCH -p submit
 
PORT=$(python -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

echo "********************************************************************" 
echo "Starting sshd in Slurm as user"
echo "Environment information:" 
echo "Date:" $(date)
echo "Allocated node:" $(hostname)
echo "Node IP:" $(ip a | grep 131.159)
echo "Path:" $(pwd)
echo "Listening on:" $PORT
echo "********************************************************************" 

/usr/sbin/sshd -D -p ${PORT} -f /dev/null -h ${HOME}/.ssh/vcg_cluster_user_sshd
```

### Step 3: Test the connection

At this point, you should be able to connect using ssh to the Slurm job.

```bash
ssh user@node -p <PORT where the server started> -i ~/.ssh/vcg_cluster_user_sshd
```

Notice that the ssh session can only see the resources allocated to the job (for example the gpus).

### Step 4: Connect your IDE

Finally, use your IDEs "Remote Connection" feature to connect to the job.

### Step 5: Remember to end the `sshd` process

It is important to cancel the Slurm job when we don't need the `sshd` listening anymore.

## 📑 References

[1]: https://code.visualstudio.com/
[[1]]: https://code.visualstudio.com/

[2]: https://www.lunarvim.org/
[[2]]: https://www.lunarvim.org/

[3]: https://slurm.schedmd.com/
[[3]]: https://slurm.schedmd.com/

[4]: https://www.jetbrains.com/help/pycharm/getting-started.html
[[4]]: https://www.jetbrains.com/help/pycharm/getting-started.html

[5]: https://coder.com/docs/code-server/latest
[[5]]: https://coder.com/docs/code-server/latest
