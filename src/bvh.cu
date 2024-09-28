#include "bvh.h"
LinearBVHNode* dev_nodes = NULL;

__global__ void updateMortonCodesCuda(BVHAccel::MortonPrimitive* mortonPrims, BVHAccel::BVHPrimitiveInfo* primitiveInfo, BVHAccel::AABB* bounds, int nPrimitives)
{
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= nPrimitives)
		return;

	const int mortonBits = 10;
	const int mortonScale = 1 << mortonBits;

	// << Update mortonPrims[i] for ith primitive >>
	mortonPrims[index].primitiveIndex = primitiveInfo[index].primitiveNumber;
	glm::vec3 centroidOffset = bounds->Offset(primitiveInfo[index].centroid);
	mortonPrims[index].mortonCode = BVHAccel::EncodeMorton3(centroidOffset * static_cast<float>(mortonScale));
}

void BVHAccel::updateMortonCodes(std::vector<MortonPrimitive>& mortonPrims, const std::vector<BVHPrimitiveInfo>& primitiveInfo, AABB& bounds, int chunkSize) const
{
	if (mortonPrims.size() > chunkSize)
	{
		// init device memory
		MortonPrimitive* d_mortonPrims;
		cudaMalloc(&d_mortonPrims, mortonPrims.size() * sizeof(MortonPrimitive));
		cudaMemcpy(d_mortonPrims, mortonPrims.data(), mortonPrims.size() * sizeof(MortonPrimitive), cudaMemcpyHostToDevice);

		BVHPrimitiveInfo* d_primitiveInfo;
		cudaMalloc(&d_primitiveInfo, primitiveInfo.size() * sizeof(BVHPrimitiveInfo));
		cudaMemcpy(d_primitiveInfo, primitiveInfo.data(), primitiveInfo.size() * sizeof(BVHPrimitiveInfo), cudaMemcpyHostToDevice);


		// Compute Morton indices of primitives
		int blockSize = 256;
		int numBlocks = (mortonPrims.size() + blockSize - 1) / blockSize;
		updateMortonCodesCuda << <numBlocks, blockSize >> > (d_mortonPrims, d_primitiveInfo, &bounds, mortonPrims.size());

		cudaMemcpy(mortonPrims.data(), d_mortonPrims, mortonPrims.size() * sizeof(MortonPrimitive), cudaMemcpyDeviceToHost);

		cudaFree(d_mortonPrims);
		cudaFree(d_primitiveInfo);
	}
	else if (mortonPrims.size() > 0)
	{
		for (int i = 0; i < mortonPrims.size(); i++)
		{
			// << Update mortonPrims[i] for ith primitive >>
			constexpr int mortonBits = 10; // use 10 bits for each spatial dimension: x, y, z
			constexpr int mortonScale = 1 << mortonBits;
			mortonPrims[i].primitiveIndex = primitiveInfo[i].primitiveNumber;
			glm::vec3 centroidOffset = bounds.Offset(primitiveInfo[i].centroid);
			mortonPrims[i].mortonCode = EncodeMorton3(centroidOffset * static_cast<float>(mortonScale));
		}
	}
}

BVHAccel::BVHBuildNode* BVHAccel::HLBVHBuild(MemoryArena& arena,
	const std::vector<BVHPrimitiveInfo>& primitiveInfo,
	int* totalNodes,
	std::vector<std::shared_ptr<Triangle>>& orderedPrims) const

{
	// Compute bounding box of all primitive centroids
	AABB bounds;
	for (const BVHPrimitiveInfo& pi : primitiveInfo)
		bounds = AABB::Union(bounds, pi.centroid);
	// Compute Morton indices of primitives 
	std::vector<MortonPrimitive> mortonPrims(primitiveInfo.size());
	updateMortonCodes(mortonPrims, primitiveInfo, bounds, 512);

	// apply radix sort to morton codes
	RadixSort(&mortonPrims);

	// Create LBVH treelet at bottom of the BVH
	std::vector<LBVHTreelet> treeletsToBuild;
	for (int start = 0, end = 1; end <= (int)mortonPrims.size(); ++end) {
		uint32_t mask = 0b00111111111111000000000000000000;
		if (end == (int)mortonPrims.size() ||
			((mortonPrims[start].mortonCode & mask) !=
				(mortonPrims[end].mortonCode & mask))) {
			// Add entry to treeletsToBuild for this treelet
			int nPrimitives = end - start;
			int maxBVHNodes = 2 * nPrimitives - 1;
			BVHBuildNode* nodes = arena.Alloc<BVHBuildNode>(maxBVHNodes, false);
			treeletsToBuild.push_back({ start, nPrimitives, nodes });
			start = end;
		}
	}

	std::atomic<int> atomicTotal(0), orderedPrimsOffset(0);
	orderedPrims.resize(primitives.size());
	// Create LBVHs for treelets in sequential
	for (int i = 0; i < treeletsToBuild.size(); ++i) {
		// Generate LBVH for treelet
		int nodesCreated = 0;
		const int firstBitIndex = 29 - 12; // the first 12 bits have already been used for a larger partitioning
		LBVHTreelet& tr = treeletsToBuild[i];
		tr.buildNodes =
			emitLBVH(tr.buildNodes, primitiveInfo, &mortonPrims[tr.startIndex],
				tr.nPrimitives, &nodesCreated, orderedPrims,
				&orderedPrimsOffset, firstBitIndex);
		atomicTotal += nodesCreated;
	}
	*totalNodes = atomicTotal;

	std::vector<BVHBuildNode*> finishedTreelets;
	for (LBVHTreelet& treelet : treeletsToBuild)
		finishedTreelets.push_back(treelet.buildNodes);

	return buildUpperSAH(arena, finishedTreelets, 0,
		finishedTreelets.size(), totalNodes);
}

BVHAccel::BVHBuildNode* BVHAccel::emitLBVH(BVHBuildNode*& buildNodes,
	const std::vector<BVHPrimitiveInfo>& primitiveInfo,
	MortonPrimitive* mortonPrims, int nPrimitives, int* totalNodes,
	std::vector<std::shared_ptr<Triangle>>& orderedPrims,
	std::atomic<int>* orderedPrimsOffset, int bitIndex) const
{
	if (bitIndex == -1 || nPrimitives < maxPrimsInNode) {
		// Create and return leaf node of LBVH treelet 
			(*totalNodes)++;
		BVHBuildNode* node = buildNodes++;
		AABB bounds;
		int firstPrimOffset = orderedPrimsOffset->fetch_add(nPrimitives);
		for (int i = 0; i < nPrimitives; ++i) {
			int primitiveIndex = mortonPrims[i].primitiveIndex;
			orderedPrims[firstPrimOffset + i] = primitives[primitiveIndex];
			bounds = AABB::Union(bounds, primitiveInfo[primitiveIndex].bounds);
		}
		node->initLeaf(firstPrimOffset, nPrimitives, bounds);
		return node;

	}
	else {
		int mask = 1 << bitIndex;
		// Advance to next subtree level if there�s no LBVH split for this bit
		if ((mortonPrims[0].mortonCode & mask) ==
			(mortonPrims[nPrimitives - 1].mortonCode & mask))
			return emitLBVH(buildNodes, primitiveInfo, mortonPrims, nPrimitives,
				totalNodes, orderedPrims, orderedPrimsOffset,
				bitIndex - 1);

		// Find LBVH split point for this dimension
		int searchStart = 0, searchEnd = nPrimitives - 1;
		while (searchStart + 1 != searchEnd) {
			int mid = (searchStart + searchEnd) / 2;
			if ((mortonPrims[searchStart].mortonCode & mask) ==
				(mortonPrims[mid].mortonCode & mask))
				searchStart = mid;
			else
				searchEnd = mid;
		}
		int splitOffset = searchEnd;


		// Create and return interior LBVH node
		(*totalNodes)++;
		BVHBuildNode* node = buildNodes++;
		BVHBuildNode* lbvh[2] = {
			emitLBVH(buildNodes, primitiveInfo, mortonPrims, splitOffset,
					 totalNodes, orderedPrims, orderedPrimsOffset, bitIndex - 1),
			emitLBVH(buildNodes, primitiveInfo, &mortonPrims[splitOffset],
					 nPrimitives - splitOffset, totalNodes, orderedPrims,
					 orderedPrimsOffset, bitIndex - 1)
		};
		int axis = bitIndex % 3;
		node->InitInterior(axis, lbvh[0], lbvh[1]);
		return node;

	}
}

BVHAccel::BVHBuildNode* BVHAccel::buildUpperSAH(MemoryArena& arena,
	std::vector<BVHBuildNode*>& treeletRoots, int start, int end,
	int* totalNodes) const {
	int nNodes = end - start;
	if (nNodes == 1)
		return treeletRoots[start];

	(*totalNodes)++;
	BVHBuildNode* node = arena.Alloc<BVHBuildNode>();

	// Compute the bounding box that encompasses all nodes under this node
	AABB bounds;
	for (int i = start; i < end; ++i)
		bounds = AABB::Union(bounds, treeletRoots[i]->bounds);

	// Compute the bounding box of the centroids of all nodes under this node
	AABB centroidBounds;
	for (int i = start; i < end; ++i)
	{
		glm::vec3 centroid = (treeletRoots[i]->bounds.min + treeletRoots[i]->bounds.max) * 0.5f;
		centroidBounds = AABB::Union(centroidBounds, centroid);
	}

	int dim = centroidBounds.maxExtent();
	int mid = (start + end) / 2;

	if (centroidBounds.max[dim] == centroidBounds.min[dim])
	{
		// If all centroids are the same along the splitting dimension, partition arbitrarily
		mid = (start + end) / 2;
	}
	else
	{
		// Partition treelet nodes by centroid along the splitting dimension
		auto comparator = [dim](const BVHBuildNode* a, const BVHBuildNode* b)
			{
				float ca = (a->bounds.min[dim] + a->bounds.max[dim]) * 0.5f;
				float cb = (b->bounds.min[dim] + b->bounds.max[dim]) * 0.5f;
				return ca < cb;
			};
		std::nth_element(&treeletRoots[start], &treeletRoots[mid], &treeletRoots[end], comparator);
	}

	// Recursively build the upper levels of the BVH
	node->InitInterior(dim,
		buildUpperSAH(arena, treeletRoots, start, mid, totalNodes),
		buildUpperSAH(arena, treeletRoots, mid, end, totalNodes));
	node->bounds = bounds;

	return node;
}

// todo: after calling this function, update static dev_nodes.

int BVHAccel::flattenBVHTree(BVHBuildNode* node, int* offset) {
	LinearBVHNode* linearNode = &nodes[*offset];
	linearNode->bounds = node->bounds;
	int myOffset = (*offset)++;
	if (node->nPrimitives > 0) {
		linearNode->primitivesOffset = node->firstPrimOffset;
		linearNode->nPrimitives = node->nPrimitives;
	}
	else {
		//Create interior flattened BVH node
		linearNode->axis = node->splitAxis;
		linearNode->nPrimitives = 0;
		flattenBVHTree(node->children[0], offset);
		linearNode->secondChildOffset =
			flattenBVHTree(node->children[1], offset);
	}
	return myOffset;
}

void BVHAccel::RadixSort(std::vector<MortonPrimitive>* v) {
	std::vector<MortonPrimitive> tempVector(v->size());
	constexpr int bitsPerPass = 6;
	constexpr int nBits = 30;
	constexpr int nPasses = nBits / bitsPerPass;
	for (int pass = 0; pass < nPasses; ++pass) {
		// Perform one pass of radix sort, sorting bitsPerPass bits 
		int lowBit = pass * bitsPerPass;
		// Set in and out vector pointers for radix sort pass 
		std::vector<MortonPrimitive>& in = (pass & 1) ? tempVector : *v;
		std::vector<MortonPrimitive>& out = (pass & 1) ? *v : tempVector;

		// Count number of zero bits in array for current radix sort bit 
		constexpr int nBuckets = 1 << bitsPerPass;
		int bucketCount[nBuckets] = { 0 };
		constexpr int bitMask = (1 << bitsPerPass) - 1;
		for (const MortonPrimitive& mp : in) {
			int bucket = (mp.mortonCode >> lowBit) & bitMask;
			++bucketCount[bucket];
		}

		// Compute starting index in output array for each bucket 
		int outIndex[nBuckets];
		outIndex[0] = 0;
		for (int i = 1; i < nBuckets; ++i)
			outIndex[i] = outIndex[i - 1] + bucketCount[i - 1];

		// Store sorted values in output array 
		for (const MortonPrimitive& mp : in) {
			int bucket = (mp.mortonCode >> lowBit) & bitMask;
			out[outIndex[bucket]++] = mp;
		}

	}
	// Copy final result from tempVector, if needed 
	if (nPasses & 1)
		std::swap(*v, tempVector);


}

BVHAccel::BVHBuildNode* BVHAccel::recursiveBuild(MemoryArena& arena,
	std::vector<BVHPrimitiveInfo>& primitiveInfo, int start,
	int end, int* totalNodes,
	std::vector<std::shared_ptr<Triangle>>& orderedPrims) {
	BVHBuildNode* node = arena.Alloc<BVHBuildNode>();
	(*totalNodes)++;

	// compute bounds of all primitives in BVH node
	AABB bounds;
	for (int i = start; i < end; ++i)
		bounds = AABB::Union(bounds, primitiveInfo[i].bounds);

	int nPrimitives = end - start;
	if (nPrimitives == 1) {
		// create leaf node
		int firstPrimOffset = orderedPrims.size();
		for (int i = start; i < end; ++i) {
			int primNum = primitiveInfo[i].primitiveNumber;
			orderedPrims.push_back(primitives[primNum]);
		}
		node->initLeaf(firstPrimOffset, nPrimitives, bounds);
		return node;
	}
	else {
		// Compute bound of primitive centroids, choose split dimension dim
		AABB centroidBounds; // initialize?
		for (int i = start; i < end; ++i)
			centroidBounds = AABB::Union(centroidBounds, primitiveInfo[i].centroid);
		int dim = centroidBounds.maxExtent();

		//Partition primitives into two sets and build children
		int mid = (start + end) / 2;
		if (centroidBounds.max[dim] == centroidBounds.min[dim]) {
			// Create leaf BVHBuildNode 
			int firstPrimOffset = orderedPrims.size();
			for (int i = start; i < end; ++i) {
				int primNum = primitiveInfo[i].primitiveNumber;
				orderedPrims.push_back(primitives[primNum]);
			}
			node->initLeaf(firstPrimOffset, nPrimitives, bounds);
			return node;
		}
		else {
			//// equal count partition
			//mid = (start + end) / 2;
			//std::nth_element(&primitiveInfo[start], &primitiveInfo[mid],
			//	&primitiveInfo[end - 1] + 1,
			//	[dim](const BVHPrimitiveInfo& a, const BVHPrimitiveInfo& b) {
			//		return a.centroid[dim] < b.centroid[dim];
			//	});

			// SAH partition
			if (nPrimitives <= 4) {
				// Partition primitives into equally sized subsets
				mid = (start + end) / 2;
				std::nth_element(&primitiveInfo[start], &primitiveInfo[mid],
					&primitiveInfo[end - 1] + 1,
					[dim](const BVHPrimitiveInfo& a, const BVHPrimitiveInfo& b) {
						return a.centroid[dim] < b.centroid[dim];
					});
			}
			else {
				// Allocate BucketInfo for SAH partition buckets
				constexpr int nBuckets = 12;
				struct BucketInfo {
					int count = 0;
					AABB bounds;
				};
				BucketInfo buckets[nBuckets];

				// Initialize BucketInfo for SAH partition buckets
				for (int i = start; i < end; ++i) {
					int b = nBuckets *
						centroidBounds.Offset(primitiveInfo[i].centroid)[dim];
					if (b == nBuckets) b = nBuckets - 1;
					buckets[b].count++;
					buckets[b].bounds = AABB::Union(buckets[b].bounds, primitiveInfo[i].bounds);
				}

				// Compute costs for splitting after each bucket
				float cost[nBuckets - 1];
				for (int i = 0; i < nBuckets - 1; ++i) {
					AABB b0, b1;
					int count0 = 0, count1 = 0;
					for (int j = 0; j <= i; ++j) {
						b0 = AABB::Union(b0, buckets[j].bounds);
						count0 += buckets[j].count;
					}
					for (int j = i + 1; j < nBuckets; ++j) {
						b1 = AABB::Union(b1, buckets[j].bounds);
						count1 += buckets[j].count;
					}
					cost[i] = 0.125f + (count0 * b0.SurfaceArea() +
						count1 * b1.SurfaceArea()) / bounds.SurfaceArea();
				}

				// Find bucket to split at that minimizes SAH metric
				float minCost = cost[0];
				int minCostSplitBucket = 0;
				for (int i = 1; i < nBuckets - 1; ++i) {
					if (cost[i] < minCost) {
						minCost = cost[i];
						minCostSplitBucket = i;
					}
				}

				// Either create leaf or interior BVHBuildNode
				float leafCost = nPrimitives;
				if (nPrimitives > maxPrimsInNode || minCost < leafCost) {
					BVHPrimitiveInfo* pmid = std::partition(&primitiveInfo[start],
						&primitiveInfo[end - 1] + 1,
						[=](const BVHPrimitiveInfo& pi) {
							int b = nBuckets * centroidBounds.Offset(pi.centroid)[dim];
							if (b == nBuckets) b = nBuckets - 1;
							return b <= minCostSplitBucket;
						});
					mid = pmid - &primitiveInfo[0];
				}
				else {
					// Create leaf BVHBuildNode
					int firstPrimOffset = orderedPrims.size();
					for (int i = start; i < end; ++i) {
						int primNum = primitiveInfo[i].primitiveNumber;
						orderedPrims.push_back(primitives[primNum]);
					}
					node->initLeaf(firstPrimOffset, nPrimitives, bounds);
					return node;
				}

				// Partition primitives based on splitMethod
				node->InitInterior(dim,
					recursiveBuild(arena, primitiveInfo, start, mid,
						totalNodes, orderedPrims),
					recursiveBuild(arena, primitiveInfo, mid, end,
						totalNodes, orderedPrims));
			}
			return node;
		}
	}
	return nullptr;
}

bool __device__ Intersect(const Ray& ray, ShadeableIntersection* isect, LinearBVHNode* dev_nodes, Triangle* dev_triangles) {
	bool hit = false;
	glm::vec3 invDir(1 / ray.direction.x, 1 / ray.direction.y, 1 / ray.direction.z);
	int dirIsNeg[3] = { invDir.x < 0, invDir.y < 0, invDir.z < 0 };
	// Follow ray through BVH nodes to find primitive intersections 
		int toVisitOffset = 0, currentNodeIndex = 0;
	int nodesToVisit[64];
	float tmin = FLT_MAX;
	Triangle* hitTriangle = nullptr;
	while (true) {
		const LinearBVHNode* node = &dev_nodes[currentNodeIndex];
		// Check ray against BVH node
		if (node->bounds.IntersectP(ray)) {
			if (node->nPrimitives > 0) {
				// Intersect ray with primitives in leaf BVH node
				for (int i = 0; i < node->nPrimitives; ++i)
				{
					float tempt = dev_triangles[node->primitivesOffset + i].intersect(ray);
					if (tempt > 0)
						hit = true;
					if (tempt < tmin && tempt > 0)
					{
						tmin = tempt;
						hitTriangle = &dev_triangles[node->primitivesOffset + i];
					}
				}
						
				if (toVisitOffset == 0) break;
				currentNodeIndex = nodesToVisit[--toVisitOffset];

			}
			else {
				// Put far BVH node on nodesToVisit stack, advance to near node
					if (dirIsNeg[node->axis]) {
						nodesToVisit[toVisitOffset++] = currentNodeIndex + 1;
						currentNodeIndex = node->secondChildOffset;
					}
					else {
						nodesToVisit[toVisitOffset++] = node->secondChildOffset;
						currentNodeIndex = currentNodeIndex + 1;
					}

			}
		}
		else {
			if (toVisitOffset == 0) break;
			currentNodeIndex = nodesToVisit[--toVisitOffset];
		}

	}

	if (hit)
	{
		isect->t = tmin;
		isect->surfaceNormal = hitTriangle->getNormal();
		isect->materialId = hitTriangle->materialid;
	}
	return hit;
}