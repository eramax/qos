make a complete anlysis and review for the entire project and give me your suggestions 
    and refactoring, i want the distro to be more lightweight, currently the ram usage < 
    40MB, i want the image size around 64MB and it uses the remaining qemu disk for var 
    partition we can use install command to flash it or flash the var. also i want it 
    support qemu and real hardware and i want it support high performance and great 
    schedular. also i want it includes the basic distro terminal commands and apps. also i 
    want it support multi core and multithreaded and make the kernel mode less being used 
    like micro kernel . also i want to support capability system so i can configure the app
     what it can access (file, net, cpu, ram, prephirals, other apps etc.) with two 
    examples. also i want it has reverse proxy dns so i can host domains and exposed 
    services e.g, can be lisiting on a domain with example using bun service.ts example. 
    try to use best needed kernel configs and also search for modern and lightweight 
    services, i want the kernel and rootfs around < 64mb and very optimized and also you 
    should include some suggestions for this rom. we are currently building the server rom,
     but in the futrue we plan to make desktop support and android replacement as well or 
    make it support running android apps as well. try to dig deep and give me your ideas 
    and how we should procced. also try to fix any reduendancy e.g, we have busybox and 
    dash and uutials do we need all, also s6 is being used does it the best or should we 
    shift to something else? also the rom should support networking and joining cluster so 
    it can see other nodes fs and files and cpu and ram and resources if this is possible 
    natively.