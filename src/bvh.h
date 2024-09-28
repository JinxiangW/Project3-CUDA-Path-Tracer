#pragma once
#include "utilities.h"
#include "sceneStructs.h"
#include "memoryArena.h"


class BVHAccel
{
public:
	std::vector<std::shared_ptr<Triangle>> primitives;
	const int maxPrimsInNode;

	struct AABB
	{
		glm::vec3 min;
		glm::vec3 max;
		AABB() : min(glm::vec3(FLT_MAX)), max(glm::vec3(FLT_MIN)) {}
		static AABB Union(const AABB& b1, const AABB& b2)
		{
			AABB ret;
			ret.min = glm::min(b1.min, b2.min);
			ret.max = glm::max(b1.max, b2.max);
			return ret;
		}

		static AABB Union(const AABB& b, const glm::vec3& p)
		{
			AABB ret;
			ret.min = glm::min(b.min, p);
			ret.max = glm::max(b.max, p);
			return ret;
		}

		int maxExtent() const
		{
			glm::vec3 diag = max - min;
			if (diag.x > diag.y && diag.x > diag.z)
				return 0;
			else if (diag.y > diag.z)
				return 1;
			else
				return 2;
		}

		__host__ __device__ glm::vec3 Offset(const glm::vec3& p) const
		{
			glm::vec3 o = p - min;
			if (max.x > min.x) o.x /= max.x - min.x;
			if (max.y > min.y) o.y /= max.y - min.y;
			if (max.z > min.z) o.z /= max.z - min.z;
			return o;
		}

		float SurfaceArea() const
		{
			glm::vec3 d = max - min;
			return 2 * (d.x * d.y + d.x * d.z + d.y * d.z);
		}

		__inline__ __device__ bool IntersectP(const Ray& ray, float* hitt0 = nullptr,
			float* hitt1 = nullptr) const {
			float t0 = 0, t1 = 2000;
			for (int i = 0; i < 3; ++i) {
				float invRayDir = 1 / ray.direction[i];
				float tNear = (min[i] - ray.origin[i]) * invRayDir;
				float tFar = (max[i] - ray.origin[i]) * invRayDir;
				// Update parametric interval from slab intersection  values
				if (tNear > tFar)
				{
					float temp = tNear;
					tNear = tFar;
					tFar = temp;
				}
				// Update tFar to ensure robust ray�bounds intersection 
					tFar *= 1 + 2 * gamma(3);

				t0 = tNear > t0 ? tNear : t0;
				t1 = tFar < t1 ? tFar : t1;
				if (t0 > t1) return false;
			}
			if (hitt0) *hitt0 = t0;
			if (hitt1) *hitt1 = t1;
			return true;
		}
		
	};

	struct BVHPrimitiveInfo
	{
		int primitiveNumber;
		glm::vec3 centroid;
		AABB bounds;
	};

	struct MortonPrimitive {
		int primitiveIndex;
		uint32_t mortonCode;
	};


	struct BVHBuildNode
	{
		AABB bounds;
		BVHBuildNode* children[2];
		int splitAxis;
		int firstPrimOffset;
		int nPrimitives;

		BVHBuildNode() : bounds(), children{ nullptr, nullptr }, splitAxis(0), firstPrimOffset(0), nPrimitives(0) {}

		void initLeaf(int first, int n, const AABB& b)
		{
			firstPrimOffset = first;
			nPrimitives = n;
			bounds = b;
			children[0] = children[1] = nullptr;
		}
		void InitInterior(int axis, BVHBuildNode* c0, BVHBuildNode* c1)
		{
			children[0] = c0;
			children[1] = c1;
			bounds = AABB::Union(c0->bounds, c1->bounds);
			splitAxis = axis;
			nPrimitives = 0;
		}

	};

	struct LBVHTreelet {
		int startIndex, nPrimitives;
		BVHBuildNode* buildNodes;
	};

	struct LinearBVHNode {
		AABB bounds;
		union {
			int primitivesOffset;    // leaf
			int secondChildOffset;   // interior
		};
		uint16_t nPrimitives;  // 0 -> interior node
		uint8_t axis;          // interior node: xyz
		uint8_t pad[1];        // ensure 32 byte total size
	};


	static __inline__ __host__ __device__ uint32_t LeftShift3(uint32_t x) {
		if (x == (1 << 10)) --x;
		x = (x | (x << 16)) & 0b00000011000000000000000011111111;
		x = (x | (x << 8)) & 0b00000011000000001111000000001111;
		x = (x | (x << 4)) & 0b00000011000011000011000011000011;
		x = (x | (x << 2)) & 0b00001001001001001001001001001001;
		return x;
	}

	static __inline__ __host__ __device__ uint32_t EncodeMorton3(const glm::vec3& v) {
		return (LeftShift3(v.z) << 2) | (LeftShift3(v.y) << 1) |
			LeftShift3(v.x);
	}

	static void RadixSort(std::vector<MortonPrimitive>* v);

	BVHBuildNode* recursiveBuild(MemoryArena& arena,
		std::vector<BVHPrimitiveInfo>& primitiveInfo, int start,
		int end, int* totalNodes,
		std::vector<std::shared_ptr<Triangle>>& orderedPrims); 

	BVHBuildNode* HLBVHBuild(MemoryArena& arena,
		const std::vector<BVHPrimitiveInfo>& primitiveInfo,
		int* totalNodes,
		std::vector<std::shared_ptr<Triangle>>& orderedPrims) const;

	void updateMortonCodes(std::vector<MortonPrimitive>& mortonPrims, const std::vector<BVHPrimitiveInfo>& primitiveInfo, AABB& bounds, int chunkSize) const;

	BVHBuildNode* emitLBVH(BVHBuildNode*& buildNodes,
		const std::vector<BVHPrimitiveInfo>& primitiveInfo,
		MortonPrimitive* mortonPrims, int nPrimitives, int* totalNodes,
		std::vector<std::shared_ptr<Triangle>>& orderedPrims,
		std::atomic<int>* orderedPrimsOffset, int bitIndex) const;

	BVHBuildNode *buildUpperSAH(MemoryArena &arena,
    std::vector<BVHBuildNode *> &treeletRoots, int start, int end,
    int *totalNodes) const;

	int BVHAccel::flattenBVHTree(BVHBuildNode* node, int* offset);

	

	friend __global__ void updateMortonCodesCuda(MortonPrimitive* mortonPrims, BVHPrimitiveInfo* primitiveInfo, BVHAccel::AABB* bounds, int nPrimitives);

	LinearBVHNode* nodes = nullptr;

};
using LinearBVHNode = BVHAccel::LinearBVHNode;
extern LinearBVHNode* dev_nodes;

bool __device__ Intersect(const Ray& ray, ShadeableIntersection* isect, LinearBVHNode* dev_nodes, Triangle* dev_triangles);