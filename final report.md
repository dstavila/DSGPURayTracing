# Summary
We developed a fast distributed GPU ray tracer that has the following features:  
1. **Very Fast Ray Traversal**   
Even for scenes with 100K+ triangles, our ray tracer can achieve a throughput of 275+ Mrays/s on GTX 680 for primary ray using a **single GPU**. And we can render a 1000x1000 picture of the scene with ambient occlusion at 60+ FPS, while its CPU counterpart stays with 0.30 FPS. 
2. **Very Fast Parallel BVH Tree Construction**  
We can build BVH of scenes with 240K+ triangles in 8 ms, while the CPU build takes nearly 2 second. We use Morton codes to encode each primitive such that we can know the exact position of each node in the array. Therefore, we can build the BVH tree in fully parallel.
3. **Distributed Ray Tracing across Clusters**   
We implemented a server client mechanism for the system, which allows us to render large scenes with multiple machines and GPUs. We also implemented load-balancing algorithm to cope with heterogenous nodes.

4. **Versatile**  
Our ray tracer support most functionalities of its CPU counterpart:
* Monte Carlo sampling 
* Multiple types of BSDFs: refraction, glass, Fresnel reflection, e.g.
* Multiple types of Lights: point, directional, area, hemisphere, e.g. 

# Background
## Parallel Ray Tracing
When rendering an image of a 3D scene, ray tracer calculates each pixel by tracing a ray from the pixel through the camera pinhole into the scene and measure the irradiance along the ray path. Because pixels are independent of each other, we can fully parallelize the **trace-ray** process. We can assign each camera ray to a thread on GPU. If there is no divergence, GPU ray tracing can achieve thousands of speedup over serialized version. But the problem is that when tracing the ray using accelerating structures like Bounding Volume Hierarchy, different rays will traverse through different nodes of the BVH. This will cause serious problem like low SIMD utilization and incoherent memory access. Thus, a naive translated GPU ray tracer won't achieve much speedup (typically 10x). Sophisticated algorithms need to be designed to tackle both of these problems.

## Parallel Tree Construction
A BVH tree is usually constructed to accelerate ray-primitive intersection test. However, a traditional way is to construct tree in top-down method. This method is inherently inefficient for parallelization for 2 reasons.
1. There is sequential dependency between levels of trees. For a node, it has to find a split point of the primitives it has and then splits to two children. Construction of a node cannot start until its parent is constructed (until the primitives in this node are determined).

2. Parallelism among nodes in the same level is amortized due small number of nodes in a level for most levels in the tree. For example, GTX 680 has 16K threads to run in parallel. For a binary tree, it has 16384 nodes at 15th level. Even though we utilize parallelism in the same level, we will have very poor performance speedup as a result of low average utilization.

## Distributed Ray Tracing
Ray Tracing is computation bound. If we can utilize more machines to do Ray Tracing, we can achieve further speedup. It has great value when rendering very large and complicated scene if we can have a near linear speedup with the number of machines we use.

# Approach
## Parallel Ray Tracing
1. **Persistent Thread**
Before optimizing the **trace-ray** function, we first aim to achieve better work distribution by persistent thread. It's a good way to bypass the hardware work distribution and improve performance for heterogenous work.
The main idea is to launch enough worker threads to occupy the chip, and each thread will continuously fetch work from a global work queue. We will also maintain a local work queue to reduce contention for the global queue.

2. **Per-ray Stack**
Now let's go inside the **traverse-ray** function.
Here is a recursive version:
traverseRay(ray, BVHnode)
 if(node is a leaf)
for all triangles in node
  do ray-triangle test
 else
if(ray intersect node->lChild.bbox)
traverseRay(ray, node->lChild)
if(ray intersect node->rChild.bbox)
traverseRay(ray, node->rChild)
For recursive traversal, suppose only one thread in a warp intersect with current BVH node's left child, then all other threads will remain idle until that thread traverse through the entire subtree of the left child. 
To improve this, here is a stack-based iterative version:
traverseRay(ray, BVH node)
Stack S
while(node)
if(node is a leaf)
for all triangle in node
  do ray-triangle test
else
if(ray intersect node->lChild.bbox)
S.push(node->lChild)
 	if(ray intersect node->rChild.bbox)
S.push(node->rChild)
node = S.pop()
If we use stack based traversal, other threads will only wait for that one thread to push the left child onto the stack. Thus using a stack based traversal will reduce the number of divergence significantly. 

3. **while-while structure and speculative method** 
After adding the per-ray stack, there is still divergence in the code. Because some threads in a warp may reach a leaf node and begin doing ray-triangle intersection test, while other threads in the same warp must wait until they finish the test. So the solution is to restructure the code in a while-while way:
traverseRay(ray, BVH node)
while(ray not terminated)
while(node is not a leaf)
traverse ray
while(triangle to be test)
do triangle test
 
This will make sure that threads in a warp will only begin ray-triangle intersection test when they all reach a leaf.
If a thread reach a leaf node before other threads, it will remain idle until all threads in the warp reach a leaf. Why not let the thread buffer the leaf and keep on traversing? This is called speculative method. Using this method, we can achieve almost full SIMD utilization for the first **while** loop. 
4. **Unit triangle intersection test**
Ray-triangle intersection test is very computation intersive and limit the performance of the ray tracer. Thus, we adopt unit triangle intersection test for its less computation in the test. It's based on the idea of transforming the ray into a unit-triangle space. It do require precomputation of the triangle-specific transformation. But the cost is well amortized because each triangle is tested against thousands of rays.

## Parallel Tree Construction
1. Algorithm
We need a new tree construction algorithm to gain more parallelism compared to traditional top-down method. We exploit method proposed in [][6](http://dl.acm.org/citation.cfm?id=2383801)[][7](https://devblogs.nvidia.com/parallelforall/thinking-parallel-part-iii-tree-construction-gpu/).

First we arrange all primitives in linear sequence following z-order curve traversal order. Z-order curve has two properties. It fills up the space and near objects in traversal order are also near in space. By first normalizing x, y, z positions into range [0, 1] and interleaving binary representations of three dimensions, we gain a code called Morton code for each primitive. Visiting primitives in increasing order of their Morton code is equivalent to traversing primitives following a z-order curve.

We sort all primitives according to their Morton codes and construct a Binary Radix Tree based on that. A node represents a range of primitives in sorted order. We split a node at the point where last primitive in left range and first primitive in right range have shortest common prefix. In this way, an internal node is at either the beginning or the end of the range it belongs to. Now we know one end and we can use binary search to efficiently find the other end.

The above property holds for all nodes in the tree and thus we can directly locate the children of an internal node. In this way, we can bulid the tree in fully parallel. For N primitives, the tree has N leaf nodes and N - 1 internal nodes. By storing leaves and internal nodes to two arrays, the relationship between nodes and positions of nodes are determined.

2. Reduce Memory Bandwidth Consumption
The algorithm requires uniqueness of Morton code. However, due to close positions of primitives in space and normalization, it is highly likely to have duplicate Morton codes for multiple primitives. To deduplicate Morton codes, we decided to use 64 bits for coding. Highest 32 bits store the computed Morton code while the lowest 32 bits store the original index of primitive.

We use Cuda thrust sort_by_key function to sort primitives with their Morton codes. Both primitives and Morton codes will be sorted in this way. However, the sorting consumes a lot of time and diminishes the benefit of parallel tree construction. We suspected that 64 bits codes cost too much memory and the sorting algorithm is memory bandwidth bounded. To solve this problem, we only store the 32 bits Morton code and concatenate it with primitive index to generate 64-bit code on the fly when needed. In this way, the Cuda thrust sort_by_key function only needs to sort array of 32-bit element and gains a 2x speedup.

3. Tree Collapse to Reduce Divergence in Tree Traversal

The tree we build has only one primitive in each leaf node. It increases divergence in tree traversal process. To reduce divergence, we decide to collapse all nodes with fewer or equal to 4 primitives to a leaf. As all internal nodes are stored in an array, the tree collapse process is also fully parallelized.

## Distributed Ray Tracing

We build a server-client framework. Master node uses its own computing power to do Ray Tracing and it is also responsible for listening connections from worker nodes and distribute work to worker nodes. Our assumption is that each worker node has access to the scene file and camera info and thus the master node only needs to send positions of start and end pixel as a request to worker nodes. In this way, the communication among nodes is effectively decreased.

Master node separates the scene into multiple tiles and puts tiles in a thread-safe work queue. Whenever a worker connects to master, a thread is created for the worker node. The thread has only one work to do. It repeatedly fetches work from work queue, sends it to worker node and receives result until the work queue is empty.

In our implementation, each time master renders a tile itself, it loads the data form GPU to host memory and updates display frame buffer and then starts rendering the next tile. This sequential part is one reason that leads to non-linear speedup across clusters in Results section. Cuda supports binding a buffer directly to device and in this way, we can effectively decrease time of this sequential part to achieve better scalability.

# Results

## Ray Tracing
The table illustrates the GPU acceleration of Ray Tracing on a **Single GTX680 GPU**. FPS represents how many times tracer can sample each pixel for an 1000x1000-pixel scene in one second. Rendering time is calculated using 256 samples per pixel. The CPU FPS and time is measured using a single thread.

![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/GPU%20Ray%20Tracing%20table.png?raw=true)

We can see that primary ray can achieve a throughput of 200+ M rays/s for scenes with hundred thoudsands of triangles. We have used some performance tool to analyze the ray tracer. We find that for primary ray the ray tracer is computation bounded. Also, the divergence is not high. This is because nearby rays in global queue also has spatial locality and similar direction in 3D space. So they are likely to traverse BVH in a similar path. For ambient occlusion ray and secondary ray, nearby rays hardly have both spatial locality and similar direction, so the divergence is much higher.

## Parallel Tree Construction
The table illustrates the GPU parallel BVH tree construction speedup. As we can see from the table, when there are 100K triangles, parallel BVH tree construction can achieve almost 200x speedup. (It is compared with a single threaded CPU)
![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/GPU%20BVH%20build%20table.png?raw=true)

In this chart, Y axis denotes Nlog(N) where N is the number of primitives. X axis is the parallel BVH tree construction time. As is shown in the figure, the parallel BVH tree construction is a Nlog(N) algorithm.
![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/GPU%20BVH%20build%20chart.png?raw=true)

## Distributed Ray Tracing
For the image below, we deliberately set different sample numbers to two nodes to illustrate that the final result is a combination of results from nodes. Note the obvious border line in the bottom part of the result image.

![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/work%20distribution.png?raw=true)

When there are 2 nodes, it almost achieves 2x speedup. As the number of nodes increases, the speedup is less linear. There are three possible reasons.
1. As we talked about in Approach section,  sequential memory access in master node operation limits scalability.
2. Width and height of scene may not be multiples of image size. On the border of an image, a tile may cover ineffective area and leads to inperfect load balancing among nodes.
3. Number of tiles may not be a multiple of number of nodes. The master has to wait for the worker which has the last tile.

![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/Distributed%20Ray%20Tracing%20chart.png?raw=true)

## Rendered High Quality Images
![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/Screen%20Shot%20GPU%20Sat%20May%20%207%2012:50:23%202016.png?raw=true)

![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/Screen%20Shot%20GPU%20Sat%20May%20%207%2010:56:18%202016.png?raw=true)

![](https://github.com/Khrylx/DSGPURayTracing/blob/gh-pages/images/Screen%20Shot%20GPU%20Sat%20May%20%207%2011:23:08%202016.png?raw=true)

## Demo
**Video:**
<a href="http://www.youtube.com/watch?feature=player_embedded&v=gOYezPrPIWc
" target="_blank"><img src="http://img.youtube.com/vi/gOYezPrPIWc/0.jpg" 
alt="IMAGE ALT TEXT HERE" width="240" height="180" border="10" /></a>

Combining our GPU Ray Tracing and Distributed Ray Tracing together, we can render a scene with 100K triangles with 32 samples / pixel in **0.4 seconds**. (4 worker nodes)

It takes **20 seconds** to render only 1 images with same configuration on an Intel Core i7 CPU with 8 threads.

# References

[1] [Günther, Johannes, et al. "Realtime ray tracing on GPU with BVH-based packet traversal." Interactive Ray Tracing, 2007. RT'07. IEEE Symposium on. IEEE, 2007.](http://ieeexplore.ieee.org/xpls/abs_all.jsp?arnumber=4342598&tag=1)
[2] [Shih, Min, et al. "Real-time ray tracing with cuda." Algorithms and Architectures for Parallel Processing. Springer Berlin Heidelberg, 2009. 327-337.](http://ieeexplore.ieee.org/xpls/abs_all.jsp?arnumber=4342598&tag=1)
[3] [Purcell, Timothy J., et al. "Ray tracing on programmable graphics hardware." ACM Transactions on Graphics (TOG). Vol. 21. No. 3. ACM, 2002.](http://dl.acm.org/citation.cfm?id=566640)
[4] [Popov, Stefan, et al. "Stackless KD‐Tree Traversal for High Performance GPU Ray Tracing." Computer Graphics Forum. Vol. 26. No. 3. Blackwell Publishing Ltd, 2007.](http://onlinelibrary.wiley.com/doi/10.1111/j.1467-8659.2007.01064.x/full)
[5] [Garanzha, Kirill, and Charles Loop. "Fast Ray Sorting and Breadth‐First Packet Traversal for GPU Ray Tracing." Computer Graphics Forum. Vol. 29. No. 2. Blackwell Publishing Ltd, 2010.](http://onlinelibrary.wiley.com/doi/10.1111/j.1467-8659.2009.01598.x/full)
[6] [Karras, Tero. "Maximizing parallelism in the construction of BVHs, octrees, and k-d trees." Proceedings of the Fourth ACM SIGGRAPH/Eurographics conference on High-Performance Graphics. Eurographics Association, 2012.](http://dl.acm.org/citation.cfm?id=2383801)
[7] [Karras. "Thinking Parallel, Part III: Tree Construction on the GPU"](https://devblogs.nvidia.com/parallelforall/thinking-parallel-part-iii-tree-construction-gpu/)

# Check Point 
https://github.com/Khrylx/DSGPURayTracing/wiki