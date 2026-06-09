# ACES Backup

## Intro

This repo is a regular backup for our research group's directory on the [NSF ACES](https://hprc.tamu.edu/aces/) computing platform. All our data set creation, container build, execution, and analysis scripts are provided and can be replicated on any SLURM batch system. Here is a breif overview of our home directory:

```
/scratch/group/p.cis260229.000/:
├── cargo-temp-*
├── containers
│   ├── build_scripts
│   │   ├── build.sh
│   │   └── rust.def
│   ├── run.sh
│   └── rust.sif
├── datasets
│   ├── high_overheads
│   ├── top_30
│   └── top_500
├── outputs
│   ├── traces
│   └── output_buffer
└── scripts
    ├── dataset_creator
    │   ├── download_dataset.sh
    │   ├── download_top_crates.sh
    │   ├── filter_unsafe.sh
    │   └── top_500_unsafe_crates.log
    ├── run_job.sh
    └── run_miri_dataset.sh
```

## Containers

ACEs uses Singularity containers, but luckily LLMs are pretty good at converting any `Dockerfile` to a `.def`, the container build file type. You can use `rust.def` as a minimal example which installs a nightly toolchain of Rust and build off that (highly recommended so you can support parallelization).

Inside `containers/build_scripts/` you can run:
```
./build.sh <def file>
```
and it will create a `.sif` in the parent folder. Behind the scenes, this puts you on a compute node with a 2 hour time limit, builds the container in your *home* directory, and copies it to `containers/`. For example, you'd write `rust.def` and do the above process to create `rust.sif`.

You can run your container in interactive mode by going back to `containers/` and running: 
```
./run.sh <sif file> <time limit in HH:MM> <memory in GB>
```
More useful scripts for running parallel jobs should be found in `scripts/`.

## Datasets

Here is where all your Rust target crates should live. We currently have:
- `high_overheads`: Isolated high overhead crates with over 100x overhead in Miri
- `top_30`: After pulling the top 30 crates from crates.io (in January 2026) and filtering for unsafe crates
- `top_500`: After pulling the top 500 crates from crates.io (in June 2026) and filtering for unsafe crates

Please give your datasets a parent folder like these, or use the scripts in `scripts/dataset_creator/`.

## Scripts

### Creating Datasets
`scripts/dataset_creator/` should contain scripts for making datasets. Your destination folder should be prefixed with `/scratch/group/p.cis260229.000/datasets/<new dataset>`. Currently it is useful for these two scenarios:
- I want to pull `N` of the crates from crates.io and filter them for unsafe, removing safe crates.
- I have a list of crates that I'd like to download from crates.io

For the first, run:
```
./download_top_crates.sh <N> <dest folder>
```
Then run:
```
./filter_unsafe.sh <dest folder>
```
Detailed reports of kept, removed, and failed crates are put in `_log` in your dataset folder.

For the second option, run:
```
./download_dataset.sh <dataset list> <dest folder>
```

### Running Jobs

For the purpose of profiling Miri, I have two scripts I rely on: `run_job.sh` and `run_miri_dataset.sh`.

`run_job.sh` is an extended version of `run.sh` described earlier in `containers/`. It takes the same arguments, but with an extra `-- <command>` at the end instead of running in interactive mode. You can also set a name for the job with `-J` Feel free to reuse this script as it is pretty general purpose.

`run_miri_dataset.sh` calls `run_job.sh` a bunch of times in parallel on a dataset, with different versions of the command `cargo miri test` depending on the image. You can copy and modify this script for your own profiling purposes. Per user, you can run up to 40 jobs at a time. This script utilizes running many single-node (haha) jobs at a time, but with tremendous datasets, I imagine you should utilize running multi-node jobs (up to 64 nodes per job!).

There is also no *per-group* job limit! Things get tricky when we hit the file limit (see *Cargo Temp*).

**IMPORTANT!** Two commands you need to know to ensure your jobs run successfully:
1. Run `tmux new -s "<some name>"` (or `tmux a`) before running any long-running job script. If you lose connection, your script stops running. Having a tmux screen open prevents this from happening.
2. Check your currently running jobs with `squeue -u $USER`. If a job is taking too long, you can do `scancel <job id>` or cancel all your jobs with `scancel -u $USER`.

## Cargo Temp (how we parallelize)

Having a temporary per-crate folder for parallel execution is essential when doing benchmarking. Otherwise, crates building off of the same `.cargo` instance will block eachother, giving you wildly innacurate results and defeating the purpose of parallelization.

Your job scripts should have their own `cargo-temp-*` folder. If you use `scripts/run_job.sh`, it will do `cargo-temp-<user>` by default.

There is a pretty harsh limit of 500,000 files in our group directory, and by having more than a couple dozen `.cargo` folders at a time, we hit that limit often. You can remediate that by:

1. Deleting your `cargo-temp` folder if you have to `scancel` your jobs. You can also delete others' folders, but run `squeue -A p.cis260229.000` to make sure they aren't currently running jobs.
2. Offsetting some of the folders to your `/scratch/user/<username>` directory, which has a limit of 250,000 files.

You can see the current quotas on the startup splash or with `showquota`.

## Outputs

Outputs contains various `.csv` files. `outputs/traces` contain profiling traces. I have some files in `output_buffer` so that I can compare them to the latest run when refining scripts.

Basically, use this folder as you see fit. It may even better to send your outputs to your `/home/<username>` because it gets backed up.

## Rust Profiling Tips

In `run_miri_dataset.sh` I do the following for each crate:
1. run `cargo clean` (this is mainly vestigal, but on the off chance I reuse some cargo binary...)
2. run `cargo fetch`: If this fails, I report a fetch error. If we are running out of space, you will get many of these. Otherwise, looking at the stderr and adding toolchains or packages to you container helps.
3. compile with `cargo <optional tool> test --no-run --lib --tests`: This only compiles what's needed to run tests, with your tool! I time this separately and report errors as build errors.
4. finally run `cargo <optional tool> test --lib --tests`: It's **important** to isolate timing the runtime separately from the build time. I report errors here as failed tests, handled on a basis depending on if it's a Rust error, tool error, or just a failed test case.


## Useful Command Index

If the scripts available don't suffice to your benchmarking needs, here are some useful ACEs-specific commands that I've picked up that I use frequently (in addition to the two important ones noted under *Running Jobs*):


- Launching a CPU node. Necessary for doing any compute-heavy tasks. You also need to be on a node to build and run containers (the scripts in `containers/` do this for you):
```
srun --nodes=1 \
    --ntasks-per-node=1 \
    --mem=<mem>G \
    --time=<hours>:00:00 \
    --pty bash -i
```
- To build a container (alternate to `build.sh` in `containers/build_scripts/`):
```
singularity build --fakeroot <container>.sif <build file>.def
```
- For entering a container, you're likely going to need to supply a cargo binary location (alternate to `run.sh` in `containers/`):
```
singularity shell \
  --env CARGO_HOME=<your .cargo path> \
  --env RUSTUP_HOME=<your .rustup path> \
  <container>.sif
```
- `module load WebProxy`: If you get a network error, chances are you haven't run this on your current node yet.
- `chmod +x <bash script>` While not ACES-specific, I like to mark my scripts as executable so they can be run with `./`
- `tmux a` attaches the last screen you had on that node, which is helpful if you had recent commands. If you refresh the terminal, you'll see that there are three login nodes, so you'll have to be on the right one to attach the right screen.
